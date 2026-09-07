#!/usr/bin/env bash
# tools/addons.sh — Install/uninstall PHP extensions and services
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/versions.conf"
source "${LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
source "${LNMP_DIR}/lib/common.sh"
source "${LNMP_DIR}/lib/detect.sh"
source "${LNMP_DIR}/lib/extensions.sh"

check_root

ACTION="${1:-}"
TARGET="${2:-}"

case "$ACTION" in
    install)
        case "$TARGET" in
            redis|imagick|apcu|swoole|memcached|sodium|imap)
                install_extension "$TARGET"
                systemctl restart php-fpm
                ;;
            redis-server)
                detect_hardware
                install_redis_server
                systemctl start redis
                ;;
            memcached-server)
                install_memcached_server
                systemctl start memcached
                ;;
            *)
                echo "Unknown addon: ${TARGET}"
                echo "Available: redis imagick apcu swoole memcached sodium imap redis-server memcached-server"
                exit 1
                ;;
        esac
        ;;
    uninstall)
        case "$TARGET" in
            redis|imagick|apcu|swoole|memcached|sodium|imap)
                uninstall_extension "$TARGET"
                systemctl restart php-fpm
                ;;
            *)
                echo "Unknown addon: ${TARGET}"
                exit 1
                ;;
        esac
        ;;
    list)
        list_extensions
        ;;
    *)
        echo "Usage: $0 {install|uninstall|list} [extension_name]"
        echo ""
        echo "PHP extensions: redis imagick apcu swoole memcached sodium imap"
        echo "Services:       redis-server memcached-server"
        exit 1
        ;;
esac
