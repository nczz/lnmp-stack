#!/usr/bin/env bash
# tools/upgrade.sh — Upgrade Nginx, MySQL, or PHP
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/versions.conf"
source "${LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
source "${LNMP_DIR}/lib/common.sh"
source "${LNMP_DIR}/lib/detect.sh"

check_root
detect_os
detect_hardware
calc_tuning_params

TARGET="${1:-}"

case "$TARGET" in
    nginx)
        log_info "Upgrading Nginx to ${NGINX_VER}..."
        source "${LNMP_DIR}/lib/nginx.sh"

        # Backup current binary
        cp /usr/local/nginx/sbin/nginx /usr/local/nginx/sbin/nginx.old

        install_nginx

        systemctl restart nginx
        log_ok "Nginx upgraded to ${NGINX_VER}."
        ;;
    php)
        log_info "Upgrading PHP to ${PHP_VER}..."
        source "${LNMP_DIR}/lib/php.sh"
        source "${LNMP_DIR}/lib/extensions.sh"

        systemctl stop php-fpm
        install_php
        install_configured_php_extensions
        systemctl start php-fpm

        log_ok "PHP upgraded to ${PHP_VER}."
        ;;
    *)
        echo "Usage: $0 {nginx|php}"
        echo ""
        echo "Edit versions.conf to set target versions before upgrading."
        echo "Database upgrades should be done manually for safety."
        exit 1
        ;;
esac
