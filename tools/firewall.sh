#!/usr/bin/env bash
# tools/firewall.sh — Firewall management (post-install)
# Usage: lnmp firewall {status|on|off|allow|deny|list}
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/versions.conf"
source "${LNMP_DIR}/lnmp.conf"
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
source "${LNMP_DIR}/lib/common.sh"
source "${LNMP_DIR}/lib/detect.sh"
source "${LNMP_DIR}/lib/security.sh"

# Detect which firewall is currently active
_detect_active_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -i "^Status: active" >/dev/null; then
        echo "ufw"
    elif iptables -L INPUT -n 2>/dev/null | grep -i "DROP" >/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

_validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        die "Invalid port: ${port} (must be 1-65535)"
    fi
}

_save_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6
    fi
}

firewall_status() {
    local active
    active=$(_detect_active_firewall)

    echo ""
    echo "┌───────────────────────────────────────┐"
    echo "│         Firewall Status                │"
    echo "├───────────────────────────────────────┤"

    case "$active" in
        iptables)
            echo "│  Type:   iptables                      │"
            echo "│  Status: ● active                      │"
            echo "├───────────────────────────────────────┤"
            echo "│  Open ports (INPUT ACCEPT):            │"
            # Extract accepted TCP/UDP ports from iptables
            local ports
            ports=$(iptables -L INPUT -n --line-numbers 2>/dev/null | awk '/ACCEPT.*dpt:/ {match($0, /dpt:[0-9]+/); print substr($0, RSTART+4, RLENGTH-4)}' | sort -un)
            if [[ -n "$ports" ]]; then
                while IFS= read -r p; do
                    printf "│    %-35s │\n" "tcp/${p}"
                done <<< "$ports"
            else
                echo "│    (default: SSH + HTTP + HTTPS)       │"
            fi
            ;;
        ufw)
            echo "│  Type:   ufw                           │"
            echo "│  Status: ● active                      │"
            echo "├───────────────────────────────────────┤"
            echo "│  Rules:                                │"
            ufw status | tail -n +4 | while IFS= read -r line; do
                [[ -n "$line" ]] && printf "│    %-35s │\n" "$line"
            done
            ;;
        none)
            echo "│  Type:   none                          │"
            echo "│  Status: ○ inactive                    │"
            echo "│                                        │"
            echo "│  Run: lnmp firewall on                 │"
            ;;
    esac

    echo "└───────────────────────────────────────┘"
    echo ""
}

firewall_on() {
    local type="${1:-iptables}"
    local active
    active=$(_detect_active_firewall)

    check_root
    detect_os

    case "$type" in
        iptables|ufw) ;;
        *) die "Unknown firewall type: ${type}. Use 'iptables' or 'ufw'." ;;
    esac

    # If switching from one to another, disable old first
    if [[ "$active" != "none" && "$active" != "$type" ]]; then
        log_info "Switching from ${active} to ${type}..."
        _firewall_disable "$active"
    fi

    if [[ "$active" = "$type" ]]; then
        log_warn "Firewall (${type}) is already active."
        firewall_status
        return 0
    fi

    case "$type" in
        iptables) _setup_iptables ;;
        ufw)      _setup_ufw ;;
    esac

    firewall_status
}

firewall_off() {
    local active
    active=$(_detect_active_firewall)

    check_root

    if [[ "$active" = "none" ]]; then
        log_warn "Firewall is already inactive."
        return 0
    fi

    log_warn "Disabling firewall — all inbound traffic will be allowed!"
    _firewall_disable "$active"
    log_ok "Firewall disabled."
}

_firewall_disable() {
    local type="$1"

    case "$type" in
        iptables)
            iptables -F
            iptables -X
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT
            ip6tables -F
            ip6tables -X
            ip6tables -P INPUT ACCEPT
            ip6tables -P FORWARD ACCEPT
            ip6tables -P OUTPUT ACCEPT
            _save_iptables
            ;;
        ufw)
            ufw --force disable
            ;;
    esac
}

firewall_allow() {
    local port="$1"
    local proto="${2:-tcp}"
    local active

    check_root
    _validate_port "$port"
    active=$(_detect_active_firewall)

    if [[ "$active" = "none" ]]; then
        die "Firewall is not active. Run 'lnmp firewall on' first."
    fi

    case "$active" in
        iptables)
            # Check if rule already exists
            if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                log_warn "Port ${port}/${proto} is already allowed."
                return 0
            fi
            # Insert before the DROP policy takes effect (before last rule)
            iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
            ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
            _save_iptables
            log_ok "Allowed port ${port}/${proto} (IPv4 + IPv6)."
            ;;
        ufw)
            ufw allow "${port}/${proto}"
            log_ok "Allowed port ${port}/${proto}."
            ;;
    esac
}

firewall_deny() {
    local port="$1"
    local proto="${2:-tcp}"
    local active

    check_root
    _validate_port "$port"
    active=$(_detect_active_firewall)

    if [[ "$active" = "none" ]]; then
        die "Firewall is not active. Run 'lnmp firewall on' first."
    fi

    case "$active" in
        iptables)
            # Remove ACCEPT rule for this port
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
            _save_iptables
            log_ok "Denied port ${port}/${proto} (rule removed)."
            ;;
        ufw)
            ufw deny "${port}/${proto}"
            log_ok "Denied port ${port}/${proto}."
            ;;
    esac
}

firewall_list() {
    local active
    active=$(_detect_active_firewall)

    case "$active" in
        iptables)
            echo "=== IPv4 Rules ==="
            iptables -L INPUT -n --line-numbers 2>/dev/null
            echo ""
            echo "=== IPv6 Rules ==="
            ip6tables -L INPUT -n --line-numbers 2>/dev/null
            ;;
        ufw)
            ufw status numbered
            ;;
        none)
            echo "Firewall is not active."
            ;;
    esac
}

# Main dispatch
ACTION="${1:-}"
shift || true

case "$ACTION" in
    status) firewall_status ;;
    on)     firewall_on "${1:-iptables}" ;;
    off)    firewall_off ;;
    allow)  [[ -n "${1:-}" ]] || die "Usage: lnmp firewall allow <port> [tcp|udp]"
            firewall_allow "$1" "${2:-tcp}" ;;
    deny)   [[ -n "${1:-}" ]] || die "Usage: lnmp firewall deny <port> [tcp|udp]"
            firewall_deny "$1" "${2:-tcp}" ;;
    list)   firewall_list ;;
    *)
        echo "Usage: lnmp firewall {status|on|off|allow|deny|list}"
        echo ""
        echo "  status              — Show firewall status and open ports"
        echo "  on [iptables|ufw]   — Enable firewall (default: iptables)"
        echo "  off                 — Disable firewall (flush all rules)"
        echo "  allow <port> [proto]— Allow inbound port (default proto: tcp)"
        echo "  deny <port> [proto] — Remove allow rule for port"
        echo "  list                — List all current rules"
        exit 1
        ;;
esac
