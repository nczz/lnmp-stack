#!/usr/bin/env bash
# tools/vhost.sh — Virtual host management
# Interactive or CLI mode
set -euo pipefail

VHOST_DIR="/usr/local/nginx/conf/vhost"
WEBROOT_BASE="/home/wwwroot"
REWRITE_DIR="/usr/local/nginx/conf/rewrite"

show_add_usage() {
    echo "Usage: vhost.sh add <domain> [options]"
    echo ""
    echo "Options:"
    echo "  --domains \"d1 d2\"   Additional domains (aliases)"
    echo "  --webroot /path     Custom web root (default: /home/wwwroot/<domain>)"
    echo "  --rewrite name      Rewrite rule: wordpress, laravel, thinkphp, yii2, none"
    echo "  --ssl               Enable Let's Encrypt SSL"
    echo "  --redirect          Force HTTP→HTTPS 301 redirect"
    echo ""
    echo "Examples:"
    echo "  vhost.sh add example.com --rewrite wordpress --ssl"
    echo "  vhost.sh add example.com --rewrite wordpress --ssl --redirect"
    echo "  vhost.sh add example.com --domains \"www.example.com\" --rewrite laravel"
}

vhost_add() {
    local domain="" more_domains="" webroot="" rewrite="none" enable_ssl="n" force_redirect="n"

    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domains)  more_domains="$2"; shift 2 ;;
            --webroot)  webroot="$2"; shift 2 ;;
            --rewrite)  rewrite="$2"; shift 2 ;;
            --ssl)      enable_ssl="y"; shift ;;
            --redirect) force_redirect="y"; shift ;;
            --help|-h)  show_add_usage; exit 0 ;;
            -*)         echo "Unknown option: $1"; show_add_usage; exit 1 ;;
            *)          [[ -z "$domain" ]] && domain="$1" || more_domains="${more_domains:+$more_domains }$1"; shift ;;
        esac
    done

    # Interactive fallback for missing values
    if [[ -z "$domain" ]]; then
        read -r -p "Domain name (e.g. example.com): " domain
        [[ -n "$domain" ]] || { echo "Domain cannot be empty."; exit 1; }

        read -r -p "More domains (space-separated, or empty): " more_domains

        [[ -n "$webroot" ]] || {
            local default_root="${WEBROOT_BASE}/${domain}"
            read -r -p "Web root [${default_root}]: " webroot
            webroot="${webroot:-$default_root}"
        }

        echo "Available rewrite rules:"
        ls "${REWRITE_DIR}/" 2>/dev/null | sed 's/\.conf$//' | while read -r r; do echo "  $r"; done
        read -r -p "Rewrite rule (or 'none') [${rewrite}]: " input_rewrite
        rewrite="${input_rewrite:-$rewrite}"

        read -r -p "Enable SSL via Let's Encrypt? [y/N]: " enable_ssl
    fi

    webroot="${webroot:-${WEBROOT_BASE}/${domain}}"

    # Create webroot
    mkdir -p "$webroot"
    chown www:www "$webroot"

    # Generate vhost config
    local server_names="$domain"
    [[ -n "$more_domains" ]] && server_names="${domain} ${more_domains}"

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
        local script_dir="$(cd "$(dirname "$0")" && pwd)"
        local ssl_args="$domain --webroot $webroot"
        [[ -n "$more_domains" ]] && ssl_args="$ssl_args --domains \"$more_domains\""
        FORCE_REDIRECT="$force_redirect" bash "${script_dir}/ssl.sh" install $ssl_args
    fi

    echo "Virtual host ${domain} created."
    echo "  Config: ${conf_file}"
    echo "  Webroot: ${webroot}"
}

vhost_del() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || read -r -p "Domain to remove: " domain
    [[ -n "$domain" ]] || exit 1

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
        local name=$(basename "$f" .conf)
        [[ "$name" = "default" ]] && continue
        local domains=$(grep -m1 'server_name' "$f" | sed 's/.*server_name //;s/;//')
        printf "  %-30s %s\n" "$name" "$domains"
    done
}

case "${1:-}" in
    add)  shift; vhost_add "$@" ;;
    del)  shift; vhost_del "$@" ;;
    list) vhost_list ;;
    *)
        echo "Usage: vhost.sh {add|del|list}"
        echo ""
        echo "  add [domain] [options]  — Add virtual host"
        echo "  del [domain]            — Remove virtual host"
        echo "  list                    — List virtual hosts"
        echo ""
        echo "Run 'vhost.sh add --help' for add options."
        exit 1
        ;;
esac
