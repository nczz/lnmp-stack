#!/usr/bin/env bash
# tools/vhost.sh — Virtual host management
# Interactive or CLI mode
set -euo pipefail

VHOST_DIR="${VHOST_DIR:-/usr/local/nginx/conf/vhost}"
WEBROOT_BASE="${WEBROOT_BASE:-/home/wwwroot}"
REWRITE_DIR="${REWRITE_DIR:-/usr/local/nginx/conf/rewrite}"
NGINX_BIN="${NGINX_BIN:-/usr/local/nginx/sbin/nginx}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
WEB_OWNER="${WEB_OWNER:-www:www}"

# Load shared config + helpers (is_interactive, die_code, EX_* codes).
_LNMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "${_LNMP_DIR}/lnmp.conf" ]] && source "${_LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${_LNMP_DIR}/lnmp.conf.local" ]] && source "${_LNMP_DIR}/lnmp.conf.local"
[[ -f "${_LNMP_DIR}/lib/common.sh" ]] && source "${_LNMP_DIR}/lib/common.sh"

show_add_usage() {
    cat <<'EOF'
Usage:
  lnmp vhost add <domain> [options]
  vhost.sh add <domain> [options]

Required:
  <domain>                 Primary ASCII/punycode DNS name.

Options:
  --domains "d1 d2"        Additional DNS aliases. With DNS-01, a left-most
                           wildcard such as *.example.com is accepted.
  --webroot /path          Absolute web root; default: /home/wwwroot/<domain>.
  --rewrite name           Existing rewrite rule basename: wordpress, laravel,
                           thinkphp, yii2, discuzx, none.
  --ssl                    Issue/install Let's Encrypt certificate after vhost
                           reloads successfully.
  --challenge http|dns     SSL challenge type; default: http.
  --dns-provider name      DNS-01 hook: dns_cf, dns_aws, dns_ali, or dns_dp.
  --dns-credentials file   Optional root/operator-owned mode-600 credential file.
  --dns-sleep seconds      Optional DNS propagation wait, 1-3600.
  --redirect               With --ssl, force HTTP -> HTTPS 301 redirect.
  --help, -h               Show this help.

Agent / CI rules:
  - Use lnmp --yes vhost add ... to guarantee no prompts.
  - Missing/invalid domain, alias, webroot, rewrite, or DNS option exits 64
    before writing root-owned Nginx config.
  - --ssl defaults to HTTP-01. DNS-01 is explicit and requires a supported DNS
    provider plus least-privilege credentials or an AWS IAM role.
  - The HTTP vhost is reloaded before either certificate challenge runs.

Examples:
  lnmp --yes vhost add example.com --rewrite wordpress
  lnmp --yes vhost add example.com --domains "www.example.com" --ssl
  lnmp --yes vhost add example.com --domains "*.example.com" --ssl \
    --challenge dns --dns-provider dns_cf \
    --dns-credentials /etc/lnmp/cloudflare-dns.env --redirect
EOF
}

_require_option_arg() {
    local opt="$1" value="${2:-}"
    [[ -n "$value" && "$value" != -* ]] || {
        show_add_usage
        die_code "$EX_USAGE" "Missing value for ${opt}."
    }
}

_validate_rewrite() {
    local rewrite="$1"
    [[ "$rewrite" =~ ^[A-Za-z0-9_-]+$ ]] \
        || die_code "$EX_USAGE" "Invalid rewrite rule '${rewrite}'."
    [[ -f "${REWRITE_DIR}/${rewrite}.conf" ]] \
        || die_code "$EX_USAGE" "Rewrite rule not found: ${rewrite}"
}


vhost_add() {
    local domain="" more_domains="" webroot="" rewrite="none" enable_ssl="n" force_redirect="n"
    local challenge="http" dns_provider="" dns_credentials="" dns_sleep=""

    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domains)         _require_option_arg "$1" "${2:-}"; more_domains="$2"; shift 2 ;;
            --webroot)         _require_option_arg "$1" "${2:-}"; webroot="$2"; shift 2 ;;
            --rewrite)         _require_option_arg "$1" "${2:-}"; rewrite="$2"; shift 2 ;;
            --challenge)       _require_option_arg "$1" "${2:-}"; challenge="$2"; shift 2 ;;
            --dns-provider)    _require_option_arg "$1" "${2:-}"; dns_provider="$2"; shift 2 ;;
            --dns-credentials) _require_option_arg "$1" "${2:-}"; dns_credentials="$2"; shift 2 ;;
            --dns-sleep)       _require_option_arg "$1" "${2:-}"; dns_sleep="$2"; shift 2 ;;
            --ssl)             enable_ssl="y"; shift ;;
            --redirect)        force_redirect="y"; shift ;;
            --help|-h)         show_add_usage; exit 0 ;;
            -*)         show_add_usage; die_code "$EX_USAGE" "Unknown option: $1" ;;
            *)          [[ -z "$domain" ]] && domain="$1" || more_domains="${more_domains:+$more_domains }$1"; shift ;;
        esac
    done

    # Fill missing values: prompt interactively, or fail fast in non-interactive mode.
    if [[ -z "$domain" ]]; then
        if is_interactive; then
            read -r -p "Domain name (e.g. example.com): " domain
            [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain cannot be empty."

            read -r -p "More domains (space-separated, or empty): " more_domains

            [[ -n "$webroot" ]] || {
                local default_root="${WEBROOT_BASE}/${domain}"
                read -r -p "Web root [${default_root}]: " webroot
                webroot="${webroot:-$default_root}"
            }

            echo "Available rewrite rules:"
            local rule_file
            for rule_file in "${REWRITE_DIR}"/*.conf; do
                [[ -f "$rule_file" ]] || continue
                echo "  $(basename "$rule_file" .conf)"
            done
            read -r -p "Rewrite rule (or 'none') [${rewrite}]: " input_rewrite
            rewrite="${input_rewrite:-$rewrite}"

            read -r -p "Enable SSL via Let's Encrypt? [y/N]: " enable_ssl
        else
            die_code "$EX_USAGE" "Domain required. Usage: vhost.sh add <domain> [--domains \"...\"] [--webroot /path] [--rewrite name] [--ssl] [--redirect]"
        fi
    fi

    webroot="${webroot:-${WEBROOT_BASE}/${domain}}"
    validate_domain "$domain"
    [[ "$challenge" = http || "$challenge" = dns ]] \
        || die_code "$EX_USAGE" "Invalid challenge '${challenge}'. Use http or dns."
    if [[ ! "${enable_ssl}" =~ ^[Yy]$ && ( "$challenge" != http || -n "$dns_provider$dns_credentials$dns_sleep" ) ]]; then
        die_code "$EX_USAGE" "DNS challenge options require --ssl."
    fi
    if [[ "$challenge" = http ]]; then
        [[ -z "$dns_provider$dns_credentials$dns_sleep" ]] \
            || die_code "$EX_USAGE" "DNS options require --challenge dns."
    else
        [[ -n "$dns_provider" ]] \
            || die_code "$EX_USAGE" "DNS-01 requires --dns-provider."
        validate_dns_provider "$dns_provider"
        [[ -z "$dns_credentials" ]] || validate_private_file "DNS credentials file" "$dns_credentials"
        if [[ -n "$dns_sleep" ]]; then
            if [[ ! "$dns_sleep" =~ ^[0-9]+$ ]] \
                || (( dns_sleep < 1 || dns_sleep > 3600 )); then
                die_code "$EX_USAGE" "--dns-sleep must be an integer from 1 to 3600."
            fi
        fi
    fi
    local -a more_domain_list=()
    local alias normalized seen=",${domain,,},"
    if [[ -n "$more_domains" ]]; then
        read -r -a more_domain_list <<< "$more_domains"
        for alias in "${more_domain_list[@]}"; do
            if [[ "$challenge" = dns ]]; then
                validate_certificate_domain "$alias"
            else
                validate_domain "$alias"
            fi
            normalized="${alias,,}"
            [[ "$seen" != *",${normalized},"* ]] \
                || die_code "$EX_USAGE" "Duplicate vhost domain: ${alias}"
            seen+="${normalized},"
        done
    fi
    validate_abs_path "webroot" "$webroot"
    _validate_rewrite "$rewrite"


    # Create webroot
    mkdir -p "$webroot"
    chown "$WEB_OWNER" "$webroot"

    # Generate vhost config
    local server_names="$domain"
    ((${#more_domain_list[@]} > 0)) && server_names="${domain} ${more_domain_list[*]}"

    local conf_file="${VHOST_DIR}/${domain}.conf"
    cat > "$conf_file" <<EOF
server {
    listen 80;
    # listen [::]:80;
    server_name ${server_names};
    root ${webroot};
    index index.html index.htm index.php;

    access_log /home/wwwlogs/${domain}.log main;
    error_log /home/wwwlogs/${domain}.error.log;

    include rewrite/${rewrite}.conf;

    location ~ \.php\$ {
        fastcgi_pass unix:/tmp/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;
        fastcgi_param PHP_ADMIN_VALUE "open_basedir=${webroot}:/tmp/:/proc/";
    }

    location ~ /\. {
        deny all;
    }

    location ^~ /.well-known/acme-challenge/ {
        allow all;
    }
}
EOF

    # Reload Nginx so the new vhost is active (required before SSL verification)
    "$NGINX_BIN" -t && "$SYSTEMCTL_BIN" reload nginx

    # Reload the HTTP vhost first. HTTP-01 serves its challenge there; DNS-01
    # does not require port 80 but keeps one creation path for managed sites.
    if [[ "${enable_ssl}" =~ ^[Yy]$ ]]; then
        local script_dir
        script_dir="$(cd "$(dirname "$0")" && pwd)"
        local -a ssl_args=("$domain" --challenge "$challenge")
        [[ -n "$more_domains" ]] && ssl_args+=(--domains "$more_domains")
        if [[ "$challenge" = http ]]; then
            ssl_args+=(--webroot "$webroot")
        else
            ssl_args+=(--dns-provider "$dns_provider")
            [[ -n "$dns_credentials" ]] && ssl_args+=(--dns-credentials "$dns_credentials")
            [[ -n "$dns_sleep" ]] && ssl_args+=(--dns-sleep "$dns_sleep")
        fi
        FORCE_REDIRECT="$force_redirect" bash "${script_dir}/ssl.sh" install "${ssl_args[@]}"
    fi

    echo "Virtual host ${domain} created."
    echo "  Config: ${conf_file}"
    echo "  Webroot: ${webroot}"
}

vhost_del() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || { is_interactive && read -r -p "Domain to remove: " domain; }
    [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain required. Usage: vhost.sh del <domain>"

    validate_domain "$domain"

    local conf_file="${VHOST_DIR}/${domain}.conf"
    if [[ -f "$conf_file" ]]; then
        rm -f "$conf_file"
        /usr/local/nginx/sbin/nginx -t && systemctl reload nginx
        echo "Vhost ${domain} removed. (Webroot preserved at ${WEBROOT_BASE}/${domain})"
    else
        echo "Config not found: ${conf_file}"
    fi
}

vhost_list() {
    echo "Virtual hosts:"
    printf "  %-30s %s\n" "CONFIG" "SERVER_NAME"
    printf "  %-30s %s\n" "------" "-----------"
    for f in "${VHOST_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        local name domains
        name=$(basename "$f" .conf)
        [[ "$name" = "default" ]] && continue
        domains=$(grep -m1 'server_name' "$f" | sed 's/.*server_name //;s/;//')
        printf "  %-30s %s\n" "$name" "$domains"
    done
}

show_usage() {
    cat <<'EOF'
Usage:
  lnmp vhost {add|del|list}
  vhost.sh {add|del|list}

Commands:
  add <domain> [options]   Add virtual host. See: lnmp vhost add --help
  del <domain>             Remove vhost config; preserves webroot.
  list                     List configured virtual hosts.

Agent / CI rules:
  - Use lnmp --yes vhost ... for deterministic non-interactive execution.
  - Missing/invalid required values exit 64 instead of prompting.
  - Domains must be ordinary ASCII/punycode DNS names.
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



case "${1:-}" in
    add)  shift; vhost_add "$@" ;;
    del)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp vhost del <domain>"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        vhost_del "$@"
        ;;
    list|ls)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp vhost list"; exit 0; fi
        reject_extra_args "lnmp vhost list" "$@"
        vhost_list
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
