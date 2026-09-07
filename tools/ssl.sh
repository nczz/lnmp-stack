#!/usr/bin/env bash
# tools/ssl.sh — SSL certificate management
set -euo pipefail

ACME_HOME="/usr/local/acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
SSL_DIR="/usr/local/nginx/conf/ssl"
VHOST_DIR="/usr/local/nginx/conf/vhost"

# Load shared config + helpers (is_interactive, die_code, EX_* codes, Acme_Email).
# Resolve project dir from this script's location so it works installed or in-repo.
_LNMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${_LNMP_DIR}/lnmp.conf" ]] && source "${_LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${_LNMP_DIR}/lnmp.conf.local" ]] && source "${_LNMP_DIR}/lnmp.conf.local"
[[ -f "${_LNMP_DIR}/lib/common.sh" ]] && source "${_LNMP_DIR}/lib/common.sh"

# Resolve the ACME registration email from multiple sources, in priority order:
#   1. explicit argument   2. ACME_EMAIL env   3. Acme_Email in lnmp.conf.local
# Email is OPTIONAL for acme.sh (Let's Encrypt only uses it for expiry notices),
# so a missing email is NOT a hard failure — we just register without one.
_resolve_acme_email() {
    local email="${1:-}"
    [[ -z "$email" ]] && email="${ACME_EMAIL:-}"
    [[ -z "$email" ]] && email="${Acme_Email:-}"
    printf '%s' "$email"
}

show_install_usage() {
    cat <<'EOF'
Usage:
  lnmp ssl install <domain> [--domains "d2 d3"] [--webroot /path] [--keytype ec-256]
  ssl.sh install <domain> [--domains "d2 d3"] [--webroot /path] [--keytype ec-256]

Required:
  <domain>                 Primary ASCII/punycode DNS name.

Options:
  --domains "d1 d2"        Additional DNS names on the same certificate.
  --webroot /path          Existing vhost webroot; default: parsed from vhost
                           config or /home/wwwroot/<domain>.
  --keytype type           ec-256 (default), ec-384, 2048, 3072, or 4096.
  --help, -h               Show this help.

Agent / CI rules:
  - Use lnmp --yes ssl install ... to guarantee no prompts.
  - Create the HTTP vhost first. HTTP-01 needs /.well-known/acme-challenge/.
  - DNS A/AAAA must already point to this host and port 80 must be reachable.
  - Invalid domain/webroot/keytype exits 64 before acme.sh is installed.
  - acme.sh install failure exits 69; issuance/DNS/firewall failure exits 75.
  - Optional account email: ACME_EMAIL env or Acme_Email in lnmp.conf.local.

Examples:
  lnmp --yes vhost add example.com --rewrite wordpress
  ACME_EMAIL=admin@example.com lnmp --yes ssl install example.com
  lnmp --yes ssl install example.com --domains "www.example.com" --webroot /home/wwwroot/example.com
EOF
}

_require_option_arg() {
    local opt="$1" value="${2:-}"
    [[ -n "$value" && "$value" != -* ]] || {
        show_install_usage
        die_code "$EX_USAGE" "Missing value for ${opt}."
    }
}


_ensure_acme() {
    if [[ -s "$ACME_BIN" ]]; then
        return 0
    fi

    echo "Installing acme.sh..."
    local email
    email="$(_resolve_acme_email "${1:-}")"
    # Prompt only when interactive; email is optional so never block without it.
    if [[ -z "$email" ]] && is_interactive; then
        read -r -p "Email for Let's Encrypt registration (optional, press Enter to skip): " email
    fi

    if [[ -n "$email" ]]; then
        curl -sS https://get.acme.sh | sh -s email="$email" \
            || die_code "$EX_UNAVAILABLE" "Failed to install acme.sh from https://get.acme.sh"
    else
        curl -sS https://get.acme.sh | sh \
            || die_code "$EX_UNAVAILABLE" "Failed to install acme.sh from https://get.acme.sh"
    fi
    ln -sf ~/.acme.sh "$ACME_HOME"

    # Use Let's Encrypt as default CA
    "$ACME_BIN" --set-default-ca --server letsencrypt

    # Auto-upgrade
    "$ACME_BIN" --upgrade --auto-upgrade

    # Ensure cron job for auto-renewal
    if ! crontab -l 2>/dev/null | grep -q 'acme.sh'; then
        (crontab -l 2>/dev/null; echo "0 3 * * * \"$ACME_BIN\" --cron --home \"$ACME_HOME\" --reloadcmd \"systemctl reload nginx\" > /dev/null 2>&1") | crontab -
        echo "Auto-renewal cron job installed (daily 3:00 AM)."
    fi

    echo "acme.sh installed to ${ACME_HOME}"
}

ssl_install() {
    local domain="" more_domains="" webroot="" keytype="ec-256"

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keytype)  _require_option_arg "$1" "${2:-}"; keytype="$2"; shift 2 ;;
            --webroot)  _require_option_arg "$1" "${2:-}"; webroot="$2"; shift 2 ;;
            --domains)  _require_option_arg "$1" "${2:-}"; more_domains="$2"; shift 2 ;;
            --help|-h)  show_install_usage; exit 0 ;;
            -*)         show_install_usage; die_code "$EX_USAGE" "Unknown option: $1" ;;
            *)          [[ -z "$domain" ]] && domain="$1" || more_domains="${more_domains:+$more_domains }$1"; shift ;;
        esac
    done

    # Validate required args BEFORE any side effects (e.g. installing acme.sh).
    [[ -n "$domain" ]] || { is_interactive && read -r -p "Domain (e.g. example.com): " domain; }
    [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain required. Usage: ssl.sh install <domain> [--domains \"d2 d3\"] [--webroot /path]"


    if [[ -z "$more_domains" ]] && is_interactive; then
        read -r -p "More domains (space-separated, or empty): " more_domains
    fi
    validate_domain "$domain"
    local -a more_domain_list=()
    if [[ -n "$more_domains" ]]; then
        read -r -a more_domain_list <<< "$more_domains"
        validate_domain_list "${more_domain_list[@]}"
    fi
    [[ "$keytype" =~ ^(ec-256|ec-384|2048|3072|4096)$ ]] \
        || die_code "$EX_USAGE" "Invalid key type '${keytype}'. Use ec-256, ec-384, 2048, 3072, or 4096."


    if [[ -z "$webroot" ]]; then
        local vhost_conf="${VHOST_DIR}/${domain}.conf"
        if [[ -f "$vhost_conf" ]]; then
            webroot=$(grep -m1 'root ' "$vhost_conf" | awk '{print $2}' | tr -d ';')
        fi
        [[ -z "$webroot" ]] && webroot="/home/wwwroot/${domain}"
    fi
    validate_abs_path "webroot" "$webroot"
    _ensure_acme


    local -a domain_args=(-d "$domain")
    local d
    for d in "${more_domain_list[@]}"; do
        domain_args+=(-d "$d")
    done

    # Issue certificate (exit 0=success, 2=already exists/skip — both are OK)
    echo "Issuing certificate for ${domain}..."
    local issue_rc=0
    "$ACME_BIN" --issue "${domain_args[@]}" -w "$webroot" --keylength "$keytype" --server letsencrypt \
        || issue_rc=$?
    if [[ $issue_rc -ne 0 && $issue_rc -ne 2 ]]; then
        die_code "$EX_TEMPFAIL" "Certificate issuance failed (acme.sh exit code: ${issue_rc}). Common causes: DNS for ${domain} not yet propagated, port 80 not reachable, or firewall blocking. Safe to retry after fixing."
    fi

    # Install certificate
    local cert_dir="${SSL_DIR}/${domain}"
    mkdir -p "$cert_dir"

    local ecc_flag=""
    [[ "$keytype" == ec-* ]] && ecc_flag="--ecc"

    "$ACME_BIN" --install-cert -d "$domain" $ecc_flag \
        --key-file "${cert_dir}/key.pem" \
        --fullchain-file "${cert_dir}/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"

    echo ""
    echo "Certificate installed:"
    echo "  Key:       ${cert_dir}/key.pem"
    echo "  Fullchain: ${cert_dir}/fullchain.pem"

    # Update vhost config (auto-apply in non-interactive, ask in interactive)
    local update_vhost="y"
    if is_interactive; then
        read -r -p "Update Nginx vhost config for SSL? [Y/n]: " update_vhost
    fi
    if [[ ! "${update_vhost}" =~ ^[Nn]$ ]]; then
        _apply_ssl_vhost "$domain" "$more_domains" "$webroot" "$cert_dir"
    fi
}

ssl_renew() {
    _ensure_acme

    local domain="${1:-}"
    if [[ -n "$domain" ]]; then
        echo "Renewing certificate for ${domain}..."
        "$ACME_BIN" --renew -d "$domain" --force
    else
        echo "Renewing all certificates..."
        "$ACME_BIN" --renew-all
    fi
    systemctl reload nginx
    echo "Done."
}

ssl_revoke() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || { is_interactive && read -r -p "Domain to revoke: " domain; }
    [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain required. Usage: ssl.sh revoke <domain>"
    validate_domain "$domain"


    _ensure_acme

    "$ACME_BIN" --revoke -d "$domain"
    "$ACME_BIN" --remove -d "$domain"

    local cert_dir="${SSL_DIR}/${domain}"
    [[ -d "$cert_dir" ]] && rm -rf "$cert_dir"

    echo "Certificate for ${domain} revoked and removed."
    echo "Remember to update the Nginx vhost config."
}

ssl_list() {
    _ensure_acme
    echo "=== Installed Certificates ==="
    "$ACME_BIN" --list 2>/dev/null

    echo ""
    echo "=== Expiry Check ==="
    for cert_dir in "${SSL_DIR}"/*/; do
        [[ -f "${cert_dir}fullchain.pem" ]] || continue
        local domain expiry expiry_epoch now_epoch
        domain=$(basename "$cert_dir")
        expiry=$(openssl x509 -enddate -noout -in "${cert_dir}fullchain.pem" 2>/dev/null | cut -d= -f2)
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null) || {
            log_warn "Unable to parse certificate expiry for ${domain}"
            continue
        }
        now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        local status="✅"
        [[ $days_left -le 7 ]] && status="🔴"
        [[ $days_left -le 30 && $days_left -gt 7 ]] && status="⚠️"

        printf "  %s %-30s expires: %s (%d days)\n" "$status" "$domain" "$expiry" "$days_left"
    done
}

ssl_self() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || { is_interactive && read -r -p "Domain for self-signed cert: " domain; }
    [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain required. Usage: ssl.sh self <domain>"
    validate_domain "$domain"


    local cert_dir="${SSL_DIR}/${domain}"
    mkdir -p "$cert_dir"

    openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${cert_dir}/key.pem" \
        -out "${cert_dir}/fullchain.pem" \
        -subj "/CN=${domain}" 2>/dev/null

    echo "Self-signed certificate created:"
    echo "  Key:       ${cert_dir}/key.pem"
    echo "  Fullchain: ${cert_dir}/fullchain.pem"

    local vhost_conf="${VHOST_DIR}/${domain}.conf"
    if [[ -f "$vhost_conf" ]]; then
        local webroot="/home/wwwroot/${domain}"
        local configured_root
        configured_root=$(grep -m1 'root ' "$vhost_conf" | awk '{print $2}' | tr -d ';')
        [[ -n "$configured_root" ]] && webroot="$configured_root"

        local update_vhost="y"
        if is_interactive; then
            read -r -p "Update Nginx vhost config for SSL? [Y/n]: " update_vhost
        fi
        if [[ ! "${update_vhost}" =~ ^[Nn]$ ]]; then
            _apply_ssl_vhost "$domain" "" "$webroot" "$cert_dir"
        fi
    else
        echo "No vhost config found at ${vhost_conf}; certificate created without Nginx changes."
    fi
}

_apply_ssl_vhost() {
    local domain="$1" more_domains="$2" webroot="$3" cert_dir="$4"
    local -a more_domain_list=()
    local server_names="$domain"
    if [[ -n "$more_domains" ]]; then
        read -r -a more_domain_list <<< "$more_domains"
        server_names="${domain} ${more_domain_list[*]}"
    fi

    local vhost_conf="${VHOST_DIR}/${domain}.conf"
    [[ -f "$vhost_conf" ]] || die_code "$EX_USAGE" "Vhost config not found: ${vhost_conf}. Create the vhost before installing SSL."
    validate_domain "$domain"
    ((${#more_domain_list[@]} == 0)) || validate_domain_list "${more_domain_list[@]}"
    validate_abs_path "webroot" "$webroot"
    validate_abs_path "certificate directory" "$cert_dir"


    # Remove existing SSL block if any
    if grep -q 'listen 443' "$vhost_conf" 2>/dev/null; then
        echo "SSL block already exists in ${vhost_conf}, skipping."
        return 0
    fi

    # Detect rewrite rule from existing config
    local rewrite="none"
    local rewrite_line
    rewrite_line=$(grep -m1 'include rewrite/' "$vhost_conf" 2>/dev/null | sed 's/.*include //' | tr -d ';')
    [[ -n "$rewrite_line" ]] && rewrite="$rewrite_line"

    # Optional: redirect HTTP to HTTPS
    if ! grep -q 'return 301 https' "$vhost_conf" 2>/dev/null; then
        local do_redirect="${FORCE_REDIRECT:-}"
        if [[ "$do_redirect" != "y" ]]; then
            if is_interactive; then
                read -r -p "Redirect HTTP to HTTPS (301)? [Y/n]: " do_redirect
                [[ -z "$do_redirect" ]] && do_redirect="y"
            else
                do_redirect="y"
            fi
        fi
        if [[ "${do_redirect}" =~ ^[Yy]$ ]]; then
            # Insert redirect after the first 'index' line in the first server block only
            # shellcheck disable=SC2016 # keep nginx $host/$request_uri literals
            sed -i '0,/^\s*index /{/^\s*index /a\
\
    return 301 https://$host$request_uri;
}' "$vhost_conf" 2>/dev/null
        fi
    fi

    # Append SSL server block
    cat >> "$vhost_conf" <<EOF

server {
    listen 443 ssl;
    # listen [::]:443 ssl;
    http2 on;
    server_name ${server_names};
    root ${webroot};
    index index.html index.htm index.php;

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    ssl_dhparam /usr/local/nginx/conf/ssl/dhparam.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    access_log /home/wwwlogs/${domain}.log main;
    error_log /home/wwwlogs/${domain}.error.log;

    include ${rewrite};

    location ~ \.php\$ {
        fastcgi_pass unix:/tmp/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;
        fastcgi_param PHP_ADMIN_VALUE "open_basedir=${webroot}:/tmp/:/proc/";
    }

    location ~ /\. {
        deny all;
    }
}
EOF

    /usr/local/nginx/sbin/nginx -t && systemctl reload nginx
    echo "Nginx vhost updated with SSL."
}

show_usage() {
    cat <<'EOF'
Usage:
  lnmp ssl {install|renew|revoke|list|self}
  ssl.sh {install|renew|revoke|list|self}

Commands:
  install <domain> [options]  Issue and install Let's Encrypt certificate.
                              See: lnmp ssl install --help
  renew [domain]              Renew one certificate, or all if omitted.
  revoke <domain>             Revoke and remove certificate files.
  list                        List certificates and expiry status.
  self <domain>               Create self-signed cert; updates vhost only when
                              the vhost config already exists.

Agent / CI rules:
  - Use lnmp --yes ssl ... for deterministic non-interactive execution.
  - Domains must be ASCII/punycode DNS names.
  - Let's Encrypt install uses HTTP-01: existing vhost, correct DNS, reachable
    port 80.
  - Exit 64 = bad/missing/invalid input; 69 = acme unavailable; 75 = issuance
    tempfail safe to retry after fixing DNS/firewall/reachability.
EOF
}

has_help_arg() {
    local arg
    for arg in "$@"; do
        case "$arg" in --help|-h|help) return 0 ;; esac
    done
    return 1
}

reject_extra_args() {
    local usage="$1"
    shift
    [[ $# -eq 0 ]] && return 0
    show_usage
    die_code "$EX_USAGE" "Unexpected argument: $1. Usage: ${usage}"
}


# --- Main ---
case "${1:-}" in
    install)  shift; ssl_install "$@" ;;
    renew)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl renew [domain]"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        ssl_renew "${1:-}"
        ;;
    revoke)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl revoke <domain>"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        ssl_revoke "${1:-}"
        ;;
    list|ls)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl list"; exit 0; fi
        reject_extra_args "lnmp ssl list" "$@"
        ssl_list
        ;;
    self)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl self <domain>"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        ssl_self "${1:-}"
        ;;
    --help|-h|help) show_usage; exit 0 ;;
    "")
        show_usage
        exit 64
        ;;
    *)
        show_usage
        exit 64
        ;;
esac
