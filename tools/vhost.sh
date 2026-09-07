#!/usr/bin/env bash
# tools/vhost.sh — Virtual host management
# Interactive or CLI mode
set -euo pipefail

VHOST_DIR="/usr/local/nginx/conf/vhost"
WEBROOT_BASE="/home/wwwroot"
REWRITE_DIR="/usr/local/nginx/conf/rewrite"

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
  --domains "d1 d2"        Additional ASCII/punycode DNS aliases.
  --webroot /path          Absolute web root; default: /home/wwwroot/<domain>.
  --rewrite name           Existing rewrite rule basename: wordpress, laravel,
                           thinkphp, yii2, discuzx, none.
  --ssl                    Issue/install Let's Encrypt certificate after vhost
                           reloads successfully.
  --redirect               With --ssl, force HTTP -> HTTPS 301 redirect.
  --help, -h               Show this help.

Agent / CI rules:
  - Use lnmp --yes vhost add ... to guarantee no prompts.
  - Missing/invalid domain, alias, webroot, or rewrite exits 64 before writing
    root-owned Nginx config.
  - --ssl uses HTTP-01: DNS A/AAAA must point to this host and port 80 must be
    reachable from the internet before running.
  - --ssl reloads Nginx once for the HTTP vhost, then calls ssl install.

Examples:
  lnmp --yes vhost add example.com --rewrite wordpress
  lnmp --yes vhost add example.com --domains "www.example.com" --rewrite laravel
  ACME_EMAIL=admin@example.com lnmp --yes vhost add example.com --ssl --redirect
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

    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domains)  _require_option_arg "$1" "${2:-}"; more_domains="$2"; shift 2 ;;
            --webroot)  _require_option_arg "$1" "${2:-}"; webroot="$2"; shift 2 ;;
            --rewrite)  _require_option_arg "$1" "${2:-}"; rewrite="$2"; shift 2 ;;
            --ssl)      enable_ssl="y"; shift ;;
            --redirect) force_redirect="y"; shift ;;
            --help|-h)  show_add_usage; exit 0 ;;
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
    local -a more_domain_list=()
    if [[ -n "$more_domains" ]]; then
        read -r -a more_domain_list <<< "$more_domains"
        validate_domain_list "${more_domain_list[@]}"
    fi
    validate_abs_path "webroot" "$webroot"
    _validate_rewrite "$rewrite"


    # Create webroot
    mkdir -p "$webroot"
    chown www:www "$webroot"

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
    /usr/local/nginx/sbin/nginx -t && systemctl reload nginx

    # SSL setup (needs working vhost to serve .well-known/acme-challenge/)
    if [[ "${enable_ssl}" =~ ^[Yy]$ ]]; then
        local script_dir
        script_dir="$(cd "$(dirname "$0")" && pwd)"
        local -a ssl_args=("$domain" --webroot "$webroot")
        [[ -n "$more_domains" ]] && ssl_args+=(--domains "$more_domains")
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
