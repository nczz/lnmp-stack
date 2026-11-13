#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

source "${REPO_DIR}/versions.conf"
source "${REPO_DIR}/lnmp.conf"
source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/upgrade.sh"
source "${REPO_DIR}/lib/extensions.sh"
source "${REPO_DIR}/lib/php.sh"
LOG_FILE="${TEST_TMP}/upgrade.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" = "$expected" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

config_value() {
    local file="$1" wanted="$2" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" = \;* || "$line" = \#* || "$line" != *=* ]] && continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" = "$wanted" ]] || continue
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        printf '%s' "$value"
        return 0
    done < "$file"
    return 1
}

PHP_CONFIG_DEST_DIR="${TEST_TMP}/rendered-php"
PHP_CONFIG_PHP_BIN="${TEST_TMP}/missing-php"
PHP_MEMORY_LIMIT=256M
PHP_FPM_MAX_CHILDREN=29
PHP_FPM_START_SERVERS=7
PHP_FPM_MIN_SPARE=7
PHP_FPM_MAX_SPARE=14
_deploy_php_conf
_deploy_phpfpm_conf
config_value "${PHP_CONFIG_DEST_DIR}/php.ini" disable_functions >/dev/null \
    || fail 'generated php.ini must explicitly keep CLI disable_functions empty'
assert_eq '' "$(config_value "${PHP_CONFIG_DEST_DIR}/php.ini" disable_functions)" \
    'WP-CLI function availability'
assert_eq Off "$(config_value "${PHP_CONFIG_DEST_DIR}/php.ini" enable_dl)" \
    'runtime extension loading disabled'
assert_eq "$PHP_FPM_DISABLE_FUNCTIONS" \
    "$(config_value "${PHP_CONFIG_DEST_DIR}/php-fpm.conf" 'php_admin_value[disable_functions]')" \
    'balanced web process denylist'
assert_eq 29 "$(config_value "${PHP_CONFIG_DEST_DIR}/php-fpm.conf" pm.max_children)" \
    'FPM tuning render'

PHP_FPM_DISABLE_FUNCTIONS='exec,stream_socket_server'
_deploy_phpfpm_conf
assert_eq 'exec,stream_socket_server' \
    "$(config_value "${PHP_CONFIG_DEST_DIR}/php-fpm.conf" 'php_admin_value[disable_functions]')" \
    'operator FPM denylist override'
set +e
(_validate_php_fpm_disable_functions 'exec, shell_exec') >/dev/null 2>&1
rc=$?
set -e
assert_eq 1 "$rc" 'FPM denylist whitespace rejection'
set +e
(_validate_php_fpm_disable_functions 'exec,EXEC') >/dev/null 2>&1
rc=$?
set -e
assert_eq 1 "$rc" 'FPM denylist duplicate rejection'
PHP_FPM_DISABLE_FUNCTIONS=''
_deploy_phpfpm_conf
assert_eq '' \
    "$(config_value "${PHP_CONFIG_DEST_DIR}/php-fpm.conf" 'php_admin_value[disable_functions]')" \
    'empty compatibility override'
PHP_FPM_DISABLE_FUNCTIONS='exec,passthru,shell_exec,system,popen,proc_open,pcntl_exec,pcntl_fork'
unset PHP_CONFIG_DEST_DIR PHP_CONFIG_PHP_BIN

PHP_UPGRADE_CONFIG_ROOT="${TEST_TMP}/php-config"
mkdir -p "${PHP_UPGRADE_CONFIG_ROOT}/php.d"
cat > "${PHP_UPGRADE_CONFIG_ROOT}/php.ini" <<'EOF'
memory_limit=768M
EOF
cat > "${PHP_UPGRADE_CONFIG_ROOT}/php.d/opcache.ini" <<'EOF'
zend_extension=opcache.so
opcache.memory_consumption=256
EOF
cat > "${PHP_UPGRADE_CONFIG_ROOT}/php.d/redis.ini" <<'EOF'
extension=redis.so
redis.session.locking_enabled=1
EOF
assert_eq redis "$(_upgrade_php_dynamic_extensions)" 'managed PHP extension inventory'
_upgrade_validate_php_extensions
PHP_UPGRADE_BIN=/usr/bin/true
PHP_CONFIG_SUMMARY=$(_upgrade_php_config_summary)
[[ "$PHP_CONFIG_SUMMARY" = *'PHP dynamic extensions: redis'* ]] \
    || fail 'PHP configuration summary must include managed extensions under nounset'
printf 'zend_extension=xdebug.so\n' > "${PHP_UPGRADE_CONFIG_ROOT}/php.d/xdebug.ini"
set +e
(_upgrade_validate_php_extensions) >/dev/null 2>&1
rc=$?
set -e
assert_eq 64 "$rc" 'unmanaged PHP extension refusal'
rm -f "${PHP_UPGRADE_CONFIG_ROOT}/php.d/xdebug.ini"

PHP_CONFIG_SNAPSHOT="${TEST_TMP}/php-config-snapshot"
PHP_CONFIG_LIVE="${TEST_TMP}/php-config-live"
cp -a "$PHP_UPGRADE_CONFIG_ROOT" "$PHP_CONFIG_SNAPSHOT"
cp -a "$PHP_UPGRADE_CONFIG_ROOT" "$PHP_CONFIG_LIVE"
printf 'old security baseline\n' > "${PHP_CONFIG_SNAPSHOT}/php.d/99-lnmp-security.ini"
printf 'worker_processes auto;\n' > "${TEST_TMP}/config.before"
cp "${TEST_TMP}/config.before" "${TEST_TMP}/config.after"
_upgrade_assert_config_unchanged "${TEST_TMP}/config.before" "${TEST_TMP}/config.after" \
    Test "${TEST_TMP}/config.diff"
assert_eq '# No configuration changes.' "$(cat "${TEST_TMP}/config.diff")" \
    'protected configuration diff evidence'
chmod 0600 "${TEST_TMP}/config.after"
if _upgrade_assert_config_unchanged "${TEST_TMP}/config.before" "${TEST_TMP}/config.after" \
        Test "${TEST_TMP}/config-metadata.diff" >/dev/null 2>&1; then
    fail 'changed configuration metadata must fail preservation'
fi
printf 'new security baseline\n' > "${PHP_CONFIG_LIVE}/php.d/99-lnmp-security.ini"
_upgrade_php_configs_preserved "$PHP_CONFIG_SNAPSHOT" "$PHP_CONFIG_LIVE" \
    || fail 'operator PHP configuration and extension tuning must be preserved'
printf 'extension=imap.so\n' > "${PHP_CONFIG_LIVE}/php.d/imap.ini"
_upgrade_php_configs_preserved "$PHP_CONFIG_SNAPSHOT" "$PHP_CONFIG_LIVE" \
    || fail 'managed extension activation migration must be allowed'
printf 'auto_prepend_file=/tmp/rogue.php\n' > "${PHP_CONFIG_LIVE}/php.d/rogue.ini"
if _upgrade_php_configs_preserved "$PHP_CONFIG_SNAPSHOT" "$PHP_CONFIG_LIVE" >/dev/null 2>&1; then
    fail 'unexpected active PHP configuration must fail preservation'
fi
rm -f "${PHP_CONFIG_LIVE}/php.d/rogue.ini"
printf 'memory_limit=256M\n' > "${PHP_CONFIG_LIVE}/php.ini"
if _upgrade_php_configs_preserved "$PHP_CONFIG_SNAPSHOT" "$PHP_CONFIG_LIVE" >/dev/null 2>&1; then
    fail 'changed php.ini must fail configuration preservation'
fi

PHP_INI_SCAN_DIR="${TEST_TMP}/extension-ini"
mkdir -p "$PHP_INI_SCAN_DIR"
printf 'extension=redis.so\nredis.session.locking_enabled=1\n' > "${PHP_INI_SCAN_DIR}/custom.ini"
_enable_php_extension_ini redis
[[ ! -e "${PHP_INI_SCAN_DIR}/redis.ini" ]] \
    || fail 'existing noncanonical extension activation must not be duplicated'
assert_eq $'extension=redis.so\nredis.session.locking_enabled=1' \
    "$(cat "${PHP_INI_SCAN_DIR}/custom.ini")" 'extension tuning preservation'
_enable_php_extension_ini imagick
assert_eq 'extension=imagick.so' "$(cat "${PHP_INI_SCAN_DIR}/imagick.ini")" \
    'new extension activation'

printf 'Core\nRedis\nZend OPcache\n' > "${TEST_TMP}/modules.before"
printf 'Core\nRedis\nZend OPcache\njson\n' > "${TEST_TMP}/modules.after"
_upgrade_php_modules_preserved "${TEST_TMP}/modules.before" "${TEST_TMP}/modules.after" \
    || fail 'PHP module superset must pass'
printf 'Core\nZend OPcache\n' > "${TEST_TMP}/modules.after"
if _upgrade_php_modules_preserved "${TEST_TMP}/modules.before" "${TEST_TMP}/modules.after" >/dev/null 2>&1; then
    fail 'missing PHP module must fail capability preservation'
fi
unset PHP_UPGRADE_CONFIG_ROOT PHP_UPGRADE_BIN PHP_CONFIG_SUMMARY PHP_CONFIG_SNAPSHOT PHP_CONFIG_LIVE

assert_eq MISSING "$(_upgrade_version_status '' 1.0.0)" 'missing version'
assert_eq CURRENT "$(_upgrade_version_status 1.0.0 1.0.0)" 'current version'
assert_eq OUTDATED "$(_upgrade_version_status 1.0.0 1.0.1)" 'patch upgrade'
assert_eq AHEAD "$(_upgrade_version_status 1.1.0 1.0.9)" 'downgrade refusal'
assert_eq 8.4 "$(_upgrade_version_series 8.4.27)" 'PHP release series'
assert_eq 11.4 "$(_upgrade_version_series 11.4.13-MariaDB)" 'MariaDB release series'

_upgrade_requires_explicit_review php 8.3.15 8.4.27 \
    || fail 'PHP series transition must require review'
_upgrade_requires_explicit_review db 10.11.11 11.4.13 \
    || fail 'MariaDB series transition must require review'
_upgrade_requires_explicit_review nginx 1.26.3 1.30.6 \
    || fail 'Nginx series transition must require review'
_upgrade_requires_explicit_review redis 7.2.7 8.10.3 \
    || fail 'Redis major transition must require review'
! _upgrade_requires_explicit_review php 8.4.25 8.4.27 \
    || fail 'PHP patch upgrade must remain automatable'
! _upgrade_requires_explicit_review redis 8.10.1 8.10.3 \
    || fail 'Redis patch upgrade must remain automatable'

cat > "${TEST_TMP}/redis-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$REDIS_ARGS_FILE"
printf 'NOAUTH Authentication required.\n'
exit 1
EOF
chmod +x "${TEST_TMP}/redis-cli"
cat > "${TEST_TMP}/redis.conf" <<'EOF'
bind 127.0.0.1
port 6380
EOF
export REDIS_ARGS_FILE="${TEST_TMP}/redis-args"
REDIS_CLI_BIN="${TEST_TMP}/redis-cli"
REDIS_CONFIG_FILE="${TEST_TMP}/redis.conf"
systemctl() { return 1; }
_upgrade_redis_wait || fail 'NOAUTH must prove that Redis is command-ready'
assert_eq '-p 6380 ping' "$(cat "$REDIS_ARGS_FILE")" 'custom Redis port readiness'

cat > "${TEST_TMP}/redis-cli" <<'EOF'
#!/usr/bin/env bash
printf 'Could not connect to Redis\\n' >&2
exit 1
EOF
systemctl() { return 0; }
if _upgrade_redis_wait; then
    fail 'failed Redis service must not be reported ready'
fi
unset -f systemctl

NGINX_BUILD_OUTPUT='nginx version: nginx/1.30.4 configure arguments: --with-http_ssl_module --add-module=/opt/custom-nginx-module'
Nginx_Modules_Options=''
Enable_Nginx_Lua=n
set +e
(_upgrade_validate_nginx_modules) >/dev/null 2>&1
rc=$?
set -e
assert_eq 64 "$rc" 'untracked Nginx module refusal'
Nginx_Modules_Options='--add-module=/opt/custom-nginx-module'
_upgrade_validate_nginx_modules
NGINX_BUILD_OUTPUT='nginx version: nginx/1.30.4 configure arguments: --add-module=/tmp/lua-nginx-module-0.10.29 --add-module=/tmp/ngx_devel_kit-0.3.4'
Nginx_Modules_Options=''
Enable_Nginx_Lua=y
_upgrade_validate_nginx_modules
unset REDIS_CLI_BIN REDIS_CONFIG_FILE REDIS_ARGS_FILE
NGINX_BUILD_OUTPUT='nginx version: nginx/1.30.6 configure arguments: --with-http_ssl_module'

# Model versions installed by historical repository releases. These paths are
# intentionally classified without using the production host's filesystem.
declare -A RUNTIME=(
    [nginx]=1.26.3
    [php]=8.3.15
    [db]=10.11.11
    [redis]=7.2.7
)
_upgrade_runtime_version() { printf '%s' "${RUNTIME[$1]:-}"; }
_upgrade_state_or_empty() { printf '%s' "$OPENSSL_TARGET_LABEL"; }
_upgrade_php_security_hardened() { return 0; }
_upgrade_generated_phpinfo_absent() { return 0; }
Enable_Nginx_Openssl=n
assert_eq REVIEW "$(_upgrade_component_status nginx)" 'v1.3 Nginx transition'
assert_eq REVIEW "$(_upgrade_component_status php)" 'v1.3 PHP transition'
assert_eq REVIEW "$(_upgrade_component_status db)" 'v1.3 MariaDB transition'
assert_eq REVIEW "$(_upgrade_component_status redis)" 'v1.3 Redis transition'

RUNTIME[nginx]=1.30.4
RUNTIME[php]=8.4.25
RUNTIME[db]=11.4.13
RUNTIME[redis]=8.10.1
assert_eq OUTDATED "$(_upgrade_component_status nginx)" 'v1.6 Nginx patch transition'
assert_eq OUTDATED "$(_upgrade_component_status php)" 'v1.6 PHP patch transition'
assert_eq CURRENT "$(_upgrade_component_status db)" 'v1.6 MariaDB target'
assert_eq OUTDATED "$(_upgrade_component_status redis)" 'v1.6 Redis patch transition'

# Exercise selection semantics without touching services or downloading builds.
declare -A TEST_STATUS=()
for component in "${UPGRADE_COMPONENTS[@]}"; do
    TEST_STATUS[$component]=CURRENT
done
TEST_STATUS[nginx]=OUTDATED
TEST_STATUS[php]=REVIEW
TEST_STATUS[redis]=AHEAD
TEST_STATUS[memcached]=MISSING
_upgrade_component_status() { printf '%s' "${TEST_STATUS[$1]}"; }
check_root() { return 0; }
_upgrade_init_log() { LOG_FILE="${TEST_TMP}/apply.log"; : > "$LOG_FILE"; }
_upgrade_require_commands() { return 0; }
_upgrade_load_build_libraries() { LOADED_TARGET="$INSTALL_TARGET"; }
upgrade_plan() { return 0; }
flock() { return 0; }
LNMP_UPGRADE_LOCK_FILE="${TEST_TMP}/upgrade.lock"
APPLIED=()
_upgrade_one() { APPLIED+=("$1"); }

upgrade_apply outdated >/dev/null
assert_eq 'nginx' "${APPLIED[*]}" 'outdated selection excludes REVIEW/AHEAD/MISSING'
assert_eq 'nginx' "$LOADED_TARGET" 'Nginx-only architecture target'

APPLIED=()
upgrade_apply php >/dev/null
assert_eq 'php' "${APPLIED[*]}" 'explicit REVIEW selection'
assert_eq 'upgrade' "$LOADED_TARGET" 'general upgrade architecture target'

set +e
(upgrade_apply redis >/dev/null 2>&1)
rc=$?
set -e
assert_eq 64 "$rc" 'AHEAD selection exit code'

set +e
(upgrade_apply memcached >/dev/null 2>&1)
rc=$?
set -e
assert_eq 64 "$rc" 'MISSING selection exit code'

for component in "${UPGRADE_COMPONENTS[@]}"; do
    TEST_STATUS[$component]=CURRENT
done
TEST_STATUS[php]=REVIEW
APPLIED=()
upgrade_apply outdated >/dev/null
assert_eq '' "${APPLIED[*]}" 'outdated does not implicitly approve REVIEW'

printf 'upgrade_test: PASS\n'
