#!/usr/bin/env bash
# lib/verify.sh — Post-install verification

verify_all() {
    local target="${1:-lnmp}"
    log_info "=== Running post-install verification ==="
    local fail=0

    # Service checks
    if [[ "$target" = 'lnmp' || "$target" = 'nginx' ]]; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            log_ok "nginx: running"
        else
            log_err "nginx: NOT running"; ((fail++))
        fi
    fi

    if [[ "$target" = 'lnmp' ]]; then
        if systemctl is-active --quiet php-fpm 2>/dev/null; then
            log_ok "php-fpm: running"
        else
            log_err "php-fpm: NOT running"; ((fail++))
        fi
    fi

    # DB service (mysql or mariadb)
    if [[ "$target" = 'lnmp' || "$target" = 'db' ]]; then
        local db_svc="mysql"
        [[ "${DB_Type}" = 'mariadb' ]] && db_svc="mariadb"
        if systemctl is-active --quiet "$db_svc" 2>/dev/null; then
            log_ok "${db_svc}: running"
        else
            log_err "${db_svc}: NOT running"; ((fail++))
        fi
    fi

    # Port checks
    if [[ "$target" = 'lnmp' || "$target" = 'nginx' ]]; then
        if ss -tlnp | grep -q ":80 "; then
            log_ok "Port 80: listening"
        else
            log_err "Port 80: NOT listening"; ((fail++))
        fi
    fi
    if [[ "$target" = 'lnmp' || "$target" = 'db' ]]; then
        if ss -tlnp | grep -q ":3306 "; then
            log_ok "Port 3306: listening"
        else
            log_err "Port 3306: NOT listening"; ((fail++))
        fi
    fi

    # Binary checks
    if [[ "$target" = 'lnmp' ]]; then
        if /usr/local/php/bin/php -v &>/dev/null; then
            local php_ver_str=$(/usr/local/php/bin/php -r 'echo PHP_VERSION;')
            log_ok "PHP ${php_ver_str}: OK"
        else
            log_err "PHP binary check failed"; ((fail++))
        fi
    fi

    if [[ "$target" = 'lnmp' || "$target" = 'nginx' ]]; then
        if /usr/local/nginx/sbin/nginx -t &>/dev/null; then
            log_ok "Nginx config test: OK"
        else
            log_err "Nginx config test: FAILED"; ((fail++))
        fi
    fi

    # MySQL connection
    if [[ "$target" = 'lnmp' || "$target" = 'db' ]]; then
        if mysql -u root -e "SELECT 1;" &>/dev/null; then
            log_ok "MySQL connection: OK"
        else
            log_err "MySQL connection: FAILED"; ((fail++))
        fi
    fi

    echo ""
    if [[ $fail -eq 0 ]]; then
        log_ok "All checks passed!"
    else
        log_err "${fail} check(s) failed. Review the log: ${LOG_FILE}"
    fi

    return $fail
}
