#!/usr/bin/env bash
# install.sh — Main entry point
set -euo pipefail

# Prevent any interactive prompts from apt/needrestart/debconf
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

_NEEDRESTART_CONF='/etc/apt/apt.conf.d/99needrestart'
_NEEDRESTART_DISABLED_CONF="${_NEEDRESTART_CONF}.disabled"
_NEEDRESTART_DISABLED=0

restore_needrestart_hook() {
    if [[ "${_NEEDRESTART_DISABLED:-0}" != "1" || ! -f "$_NEEDRESTART_DISABLED_CONF" ]]; then
        return 0
    fi
    if [[ -e "$_NEEDRESTART_CONF" ]]; then
        log_warn "needrestart hook was recreated during install; leaving backup at ${_NEEDRESTART_DISABLED_CONF}."
        return 0
    fi
    mv "$_NEEDRESTART_DISABLED_CONF" "$_NEEDRESTART_CONF"
    _NEEDRESTART_DISABLED=0
}
trap restore_needrestart_hook EXIT

disable_needrestart_hook() {
    if [[ ! -f "$_NEEDRESTART_CONF" ]]; then
        if [[ -f "$_NEEDRESTART_DISABLED_CONF" ]]; then
            mv "$_NEEDRESTART_DISABLED_CONF" "$_NEEDRESTART_CONF"
            log_warn "Restored previously disabled needrestart hook before install."
        else
            return 0
        fi
    fi
    if [[ -e "$_NEEDRESTART_DISABLED_CONF" ]]; then
        log_warn "needrestart hook backup already exists; leaving current hook enabled."
        return 0
    fi
    mv "$_NEEDRESTART_CONF" "$_NEEDRESTART_DISABLED_CONF"
    _NEEDRESTART_DISABLED=1
}

LNMP_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
AUTO_MODE='n'
RESUME_MODE='n'
INSTALL_TARGET=''
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_MODE='y' ;;
        --resume) RESUME_MODE='y' ;;
        lnmp|nginx|db) INSTALL_TARGET="$arg" ;;
        *) echo "Usage: $0 [--auto] [--resume] {lnmp|nginx|db}"; exit 1 ;;
    esac
done
[[ -n "$INSTALL_TARGET" ]] || { echo "Usage: $0 [--auto] [--resume] {lnmp|nginx|db}"; exit 1; }

# Load config (lnmp.conf = defaults, lnmp.conf.local = user overrides)
source "${LNMP_DIR}/versions.conf"
source "${LNMP_DIR}/lnmp.conf"
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
source "${LNMP_DIR}/lib/common.sh"
source "${LNMP_DIR}/lib/detect.sh"
source "${LNMP_DIR}/lib/deps.sh"
source "${LNMP_DIR}/lib/nginx.sh"
source "${LNMP_DIR}/lib/mysql.sh"
source "${LNMP_DIR}/lib/php.sh"
source "${LNMP_DIR}/lib/extensions.sh"
source "${LNMP_DIR}/lib/security.sh"
source "${LNMP_DIR}/lib/verify.sh"

[[ "$AUTO_MODE" = 'y' ]] && Auto_Install='y'

# Step progress tracking for --resume
_PROGRESS_FILE="${LNMP_DIR}/.install-progress"

mark_step() { echo "$1" >> "$_PROGRESS_FILE"; }

step_done() {
    [[ "$RESUME_MODE" = 'y' ]] && grep -qxF "$1" "$_PROGRESS_FILE" 2>/dev/null
}

# Fresh install: clear previous progress
[[ "$RESUME_MODE" != 'y' ]] && rm -f "$_PROGRESS_FILE"

# Start
print_banner
check_root

# Disable needrestart apt hook during install, then restore it on every exit path.
disable_needrestart_hook

START_TIME=$(date +%s)
echo "Install log: ${LOG_FILE}"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

# Detect environment
detect_os
check_os_support
detect_hardware
calc_tuning_params

# Interactive prompts (skip if --auto)
if [[ "${Auto_Install}" != 'y' && "$INSTALL_TARGET" = 'lnmp' ]]; then
    echo ""
    echo "Current configuration:"
    echo "  Database: ${DB_Type} (${MYSQL_VER}/${MARIADB_VER})"
    echo "  PHP: ${PHP_VER}"
    echo "  Nginx: ${NGINX_VER}"
    echo "  Timezone: ${Timezone}"
    echo ""
    read -r -p "Press Enter to start installation, or Ctrl+C to cancel..."
fi

# Prepare system
echo ""
if step_done prepare; then
    log_ok "[1/7] System preparation — already done, skipping."
else
    log_info "[1/7] Preparing system environment..."
    prepare_system
    check_env_conflicts
    mark_step prepare
fi

# Batch install PHP extensions from config
_install_php_extensions() {
    [[ -n "${PHP_Extensions_Install:-}" ]] || return 0
    log_info "Installing PHP extensions: ${PHP_Extensions_Install}"
    for ext in ${PHP_Extensions_Install}; do
        install_extension "$ext"
    done
}

# Step verification — stop on failure
verify_step() {
    local name="$1"
    shift
    if "$@"; then
        log_ok "${name}: verified"
    else
        die "${name}: verification FAILED. Check ${LOG_FILE} and fix before re-running."
    fi
}

verify_nginx() {
    /usr/local/nginx/sbin/nginx -t 2>/dev/null
}

verify_mysql() {
    local db_svc="mysql"
    [[ "${DB_Type}" = 'mariadb' ]] && db_svc="mariadb"
    systemctl is-active --quiet "$db_svc" && \
    /usr/local/mysql/bin/mysqladmin -u root ping &>/dev/null
}

verify_php() {
    /usr/local/php/bin/php -v &>/dev/null && \
    [[ -f /usr/local/php/etc/php-fpm.conf ]]
}

db_label() {
    [[ "${DB_Type}" = 'mariadb' ]] && echo "MariaDB" || echo "MySQL"
}

db_version() {
    [[ "${DB_Type}" = 'mariadb' ]] && echo "${MARIADB_VER}" || echo "${MYSQL_VER}"
}

# Install based on target
case "$INSTALL_TARGET" in
    lnmp)
        if step_done nginx; then
            log_ok "[2/7] Nginx — already installed, skipping."
        else
            log_info "[2/7] Compiling Nginx ${NGINX_VER}..."
            install_nginx
            verify_step "Nginx" verify_nginx
            mark_step nginx
        fi

        if step_done mysql; then
            log_ok "[3/7] $(db_label) — already installed, skipping."
        else
            log_info "[3/7] Installing $(db_label) $(db_version)..."
            install_mysql
            verify_step "$(db_label)" verify_mysql
            mark_step mysql
        fi

        if step_done php; then
            log_ok "[4/7] PHP — already installed, skipping."
        else
            log_info "[4/7] Compiling PHP ${PHP_VER} (this takes the longest)..."
            install_php
            verify_step "PHP" verify_php
            mark_step php
        fi

        if step_done tools; then
            log_ok "[5/7] Tools — already installed, skipping."
        else
            log_info "[5/7] Installing tools (WP-CLI, extensions)..."
            install_wp_cli
            _install_php_extensions
            mark_step tools
        fi
        ;;
    nginx)
        log_info "[2/2] Compiling Nginx ${NGINX_VER}..."
        install_nginx
        verify_step "Nginx" verify_nginx
        ;;
    db)
        log_info "[2/2] Installing $(db_label) $(db_version)..."
        install_mysql
        verify_step "$(db_label)" verify_mysql
        ;;
esac

# Security hardening
log_info "[6/7] Applying security hardening..."
apply_security

# Start services (non-fatal — port conflicts should not abort installation)
case "$INSTALL_TARGET" in
    lnmp)
        systemctl start nginx 2>/dev/null || log_warn "Nginx failed to start (port conflict?). Start manually after resolving."
        systemctl start php-fpm 2>/dev/null || log_warn "PHP-FPM failed to start. Check: systemctl status php-fpm"
        ;;
    nginx)
        systemctl start nginx 2>/dev/null || log_warn "Nginx failed to start (port conflict?). Start manually after resolving."
        ;;
esac

# Install lnmp management command (symlink to source)
ln -sf "${LNMP_DIR}/tools/lnmp" /usr/bin/lnmp

# Install bash completion
if [[ -d /etc/bash_completion.d ]]; then
    cp "${LNMP_DIR}/conf/bash_completion_lnmp" /etc/bash_completion.d/lnmp
fi

# Verify
log_info "[7/7] Running verification..."
verify_all "$INSTALL_TARGET"

# Restore needrestart hook before success cleanup; the EXIT trap covers failures.
restore_needrestart_hook

# Clean up progress file on success
rm -f "$_PROGRESS_FILE"

# Summary
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECONDS_REMAIN=$(( ELAPSED % 60 ))

echo ""
echo "+---------------------------------------------------+"
echo "|          Installation Complete!                    |"
echo "+---------------------------------------------------+"
echo "  Time elapsed: ${MINUTES}m ${SECONDS_REMAIN}s"
[[ "$INSTALL_TARGET" = 'lnmp' || "$INSTALL_TARGET" = 'nginx' ]] && echo "  Nginx: /usr/local/nginx/"
[[ "$INSTALL_TARGET" = 'lnmp' || "$INSTALL_TARGET" = 'db' ]] && echo "  $(db_label): /usr/local/mysql/"
[[ "$INSTALL_TARGET" = 'lnmp' ]] && echo "  PHP:   /usr/local/php/"
[[ "$INSTALL_TARGET" = 'lnmp' || "$INSTALL_TARGET" = 'nginx' ]] && echo "  Web root: ${Default_Website_Dir:-/home/wwwroot/default}"
echo "  Logs: /home/wwwlogs/"
echo "  Install log: ${LOG_FILE}"
[[ "$INSTALL_TARGET" = 'lnmp' || "$INSTALL_TARGET" = 'db' ]] && [[ -f /root/.my.cnf ]] && echo "  Database root password: /root/.my.cnf"
[[ "${Enable_Docker:-n}" = 'y' ]] && command -v docker &>/dev/null && echo "  Docker: $(timeout 10 docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
# Version probes are wrapped in `timeout` as a safety fuse. Composer also runs
# with --no-interaction so any unexpected first-run prompt cannot block the
# installer summary.
if [[ "$INSTALL_TARGET" = 'lnmp' && "${Enable_Composer:-n}" = 'y' && -x /usr/local/bin/composer ]]; then
    echo "  Composer: $(timeout 10 /usr/local/php/bin/php /usr/local/bin/composer --version --no-interaction 2>/dev/null | awk '{print $3}')"
fi
if [[ "$INSTALL_TARGET" = 'lnmp' && "${Enable_WP_CLI:-n}" = 'y' && -x /usr/local/bin/wp ]]; then
    echo "  WP-CLI: $(timeout 10 /usr/local/php/bin/php /usr/local/bin/wp --version --allow-root 2>/dev/null)"
fi
[[ "$INSTALL_TARGET" = 'lnmp' && -n "${PHP_Extensions_Install:-}" ]] && echo "  PHP extensions: ${PHP_Extensions_Install}"
echo ""
echo "  Management: lnmp {start|stop|restart|status}"
echo "+---------------------------------------------------+"
