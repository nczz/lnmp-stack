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

mkdir -p "${TEST_TMP}/composer-probe-bin"
cat > "${TEST_TMP}/composer-probe-bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ "$1" = '--signal=TERM' && "$2" = '--kill-after=2s' && "$3" = '10s' ]] || exit 97
shift 3
[[ "${FAKE_TIMEOUT_RC:-0}" = 0 ]] || exit "$FAKE_TIMEOUT_RC"
exec "$@"
EOF
cat > "${TEST_TMP}/composer-probe-bin/php" <<'EOF'
#!/usr/bin/env bash
[[ "${COMPOSER_ALLOW_SUPERUSER:-}" = 1 ]] || exit 90
[[ ! -t 0 ]] || exit 91
if [[ -e /proc/self/fd/0 ]]; then
    [[ "$(readlink /proc/self/fd/0)" = /dev/null ]] || exit 92
fi
[[ "$#" -eq 4 && "$2" = '--version' && "$3" = '--no-ansi' && "$4" = '--no-interaction' ]] || exit 93
printf '%s\n' "$*" > "$COMPOSER_PROBE_ARGS_FILE"
printf 'Composer version 2.11.2 2026-11-12 15:42:17\n'
EOF
: > "${TEST_TMP}/composer-probe-bin/composer"
chmod +x "${TEST_TMP}/composer-probe-bin/"{timeout,php,composer}
export COMPOSER_PROBE_ARGS_FILE="${TEST_TMP}/composer-probe-args"
probe_path="${TEST_TMP}/composer-probe-bin:${PATH}"
assert_eq 2.11.2 \
    "$(COMPOSER_PHP_BIN="${TEST_TMP}/composer-probe-bin/php" \
        COMPOSER_BIN="${TEST_TMP}/composer-probe-bin/composer" \
        PATH="$probe_path" composer_version)" \
    'non-interactive Composer version probe'
assert_eq "${TEST_TMP}/composer-probe-bin/composer --version --no-ansi --no-interaction" \
    "$(cat "$COMPOSER_PROBE_ARGS_FILE")" 'Composer probe arguments'
set +e
FAKE_TIMEOUT_RC=124 \
    COMPOSER_PHP_BIN="${TEST_TMP}/composer-probe-bin/php" \
    COMPOSER_BIN="${TEST_TMP}/composer-probe-bin/composer" \
    PATH="$probe_path" composer_version \
    >/dev/null 2>"${TEST_TMP}/composer-timeout-error"
rc=$?
set -e
assert_eq 124 "$rc" 'Composer timeout exit code'
[[ "$(cat "${TEST_TMP}/composer-timeout-error")" = *'timed out after 10 seconds'* ]] \
    || fail 'Composer timeout must provide an actionable diagnostic'
unset COMPOSER_PROBE_ARGS_FILE
DOWNLOAD_ROOT="${TEST_TMP}/download-retry"
mkdir -p "$DOWNLOAD_ROOT"
printf '0\n' > "${DOWNLOAD_ROOT}/attempts"
: > "${DOWNLOAD_ROOT}/delays"
: > "${DOWNLOAD_ROOT}/headers"
(
    cur_dir="$DOWNLOAD_ROOT"
    LOG_FILE="${DOWNLOAD_ROOT}/download.log"
    wget() {
        local output='' count
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -O)
                    output="$2"
                    shift 2
                    ;;
                --header=*)
                    [[ -s "${DOWNLOAD_ROOT}/headers" ]] \
                        || printf '%s\n' "${1#--header=}" > "${DOWNLOAD_ROOT}/headers"
                    shift
                    ;;
                *) shift ;;
            esac
        done
        count=$(<"${DOWNLOAD_ROOT}/attempts")
        ((count += 1))
        printf '%s\n' "$count" > "${DOWNLOAD_ROOT}/attempts"
        (( count >= 3 )) || return 1
        printf 'verified\n' > "$output"
    }
    sleep() { printf '%s\n' "$1" >> "${DOWNLOAD_ROOT}/delays"; }
    verify_sha256() { [[ -f "$1" && "$(<"$1")" = verified ]]; }
    download_src Retry https://example.invalid/retry-artifact.tgz \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        application/vnd.github.patch >/dev/null
)
assert_eq 3 "$(<"${DOWNLOAD_ROOT}/attempts")" 'bounded download retries'
assert_eq $'5\n20' "$(<"${DOWNLOAD_ROOT}/delays")" 'download retry backoff'
assert_eq verified "$(<"${DOWNLOAD_ROOT}/src/retry-artifact.tgz")" \
    'verified retry artifact activation'
assert_eq 'Accept: application/vnd.github.patch' \
    "$(<"${DOWNLOAD_ROOT}/headers")" 'download Accept media type'

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

LEGACY_SCAN="${PHP_UPGRADE_CONFIG_ROOT}/legacy-conf.d"
mkdir -p "$LEGACY_SCAN"
printf 'extension=imagick.so\n' > "${LEGACY_SCAN}/008-imagick.ini"
PHP_UPGRADE_SCAN_DIR="$LEGACY_SCAN"
assert_eq imagick "$(_upgrade_php_dynamic_extensions)" \
    'runtime-discovered PHP scan directory inventory'
unset PHP_UPGRADE_SCAN_DIR

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
assert_eq 8.4 "$(_upgrade_version_series 8.4.28)" 'PHP release series'
assert_eq 11.4 "$(_upgrade_version_series 11.4.13-MariaDB)" 'MariaDB release series'

_upgrade_requires_explicit_review php 8.3.15 8.4.28 \
    || fail 'PHP series transition must require review'
_upgrade_requires_explicit_review db 10.11.11 11.4.13 \
    || fail 'MariaDB series transition must require review'
_upgrade_requires_explicit_review nginx 1.26.3 1.30.7 \
    || fail 'Nginx series transition must require review'
_upgrade_requires_explicit_review redis 7.2.7 8.10.3 \
    || fail 'Redis major transition must require review'
! _upgrade_requires_explicit_review php 8.4.27 8.4.28 \
    || fail 'PHP patch upgrade must remain automatable'
! _upgrade_requires_explicit_review redis 8.10.1 8.10.3 \
    || fail 'Redis patch upgrade must remain automatable'

_upgrade_php_layout_supported /usr/local/php/etc /usr/local/php/etc/php.d \
    || fail 'project-managed PHP layout must be upgradeable'
if _upgrade_php_layout_supported /opt/php/etc /opt/php/etc/conf.d >/dev/null 2>&1; then
    fail 'nonstandard PHP config roots must require an explicit migration'
fi

PHP_LIVE_PREFIX="${TEST_TMP}/php-live"
PHP_CANDIDATE="${TEST_TMP}/php-candidate"
mkdir -p "$PHP_LIVE_PREFIX" "$PHP_CANDIDATE"
printf 'old\n' > "${PHP_LIVE_PREFIX}/version"
printf 'new\n' > "${PHP_CANDIDATE}/version"
PHP_SERVICE_ACTIONS=''
systemctl() {
    PHP_SERVICE_ACTIONS+="${PHP_SERVICE_ACTIONS:+,}$1"
    return 0
}
_deploy_php_candidate "$PHP_CANDIDATE" "$PHP_LIVE_PREFIX" php-fpm \
    || fail 'PHP candidate prefix deployment must succeed'
assert_eq new "$(cat "${PHP_LIVE_PREFIX}/version")" 'atomic PHP candidate activation'
assert_eq stop "$PHP_SERVICE_ACTIONS" 'PHP candidate deployment service stop'
[[ ! -e "$PHP_CANDIDATE" ]] || fail 'activated PHP candidate path must be consumed'
unset -f systemctl

PHP_CANDIDATE="${TEST_TMP}/php-candidate-stop-failure"
mkdir -p "$PHP_CANDIDATE"
printf 'blocked\n' > "${PHP_CANDIDATE}/version"
systemctl() { return 1; }
if _deploy_php_candidate "$PHP_CANDIDATE" "$PHP_LIVE_PREFIX" php-fpm; then
    fail 'PHP candidate deployment must stop when the service cannot stop'
fi
assert_eq new "$(cat "${PHP_LIVE_PREFIX}/version")" \
    'failed PHP candidate deployment preserves live prefix'
assert_eq blocked "$(cat "${PHP_CANDIDATE}/version")" \
    'failed PHP candidate deployment preserves candidate'
unset -f systemctl

PROC_ROOT="${TEST_TMP}/proc"
EXPECTED_SERVICE_BIN="${TEST_TMP}/expected-nginx"
mkdir -p "${PROC_ROOT}/1234"
touch "$EXPECTED_SERVICE_BIN"
EXPECTED_SERVICE_BIN="$(readlink -f "$EXPECTED_SERVICE_BIN")"
ln -s "$EXPECTED_SERVICE_BIN" "${PROC_ROOT}/1234/exe"
LNMP_UPGRADE_PROC_ROOT="$PROC_ROOT"
systemctl() {
    case "$1" in
        is-active) printf 'active\n' ;;
        show) printf '1234\n' ;;
        *) return 1 ;;
    esac
}
_upgrade_service_owned nginx "$EXPECTED_SERVICE_BIN" \
    || fail 'systemd-owned expected service binary must pass preflight'
EXPECTED_SERVICE_LINK="${TEST_TMP}/expected-nginx-link"
ln -s "$EXPECTED_SERVICE_BIN" "$EXPECTED_SERVICE_LINK"
_upgrade_service_owned nginx "$EXPECTED_SERVICE_LINK" \
    || fail 'symlinked expected service binary must resolve to the owned executable'
readlink() {
    if [[ "${1:-}" = -f && "${2:-}" = "${PROC_ROOT}/1234/exe" ]]; then
        printf '%s (deleted)\n' "$EXPECTED_SERVICE_BIN"
    else
        command readlink "$@"
    fi
}
if _upgrade_service_owned nginx "$EXPECTED_SERVICE_BIN" >/dev/null 2>&1; then
    fail 'deleted running service executable must fail preflight'
fi
unset -f readlink
rm -f "${PROC_ROOT}/1234/exe"
ln -s "${TEST_TMP}/unexpected-nginx" "${PROC_ROOT}/1234/exe"
if _upgrade_service_owned nginx "$EXPECTED_SERVICE_BIN" >/dev/null 2>&1; then
    fail 'unexpected systemd service binary must fail preflight'
fi
unset -f systemctl
unset LNMP_UPGRADE_PROC_ROOT

LNMP_UPGRADE_FREE_KB=5242880
_upgrade_validate_capacity
set +e
(LNMP_UPGRADE_FREE_KB=1048576; _upgrade_validate_capacity) >/dev/null 2>&1
rc=$?
set -e
assert_eq 69 "$rc" 'insufficient upgrade capacity exit code'
unset LNMP_UPGRADE_FREE_KB

LNMP_SOURCE_CACHE_ROOT="${TEST_TMP}/source-cache"
mkdir -p "$LNMP_SOURCE_CACHE_ROOT"
printf 'temporary\n' > "${LNMP_SOURCE_CACHE_ROOT}/artifact"
_upgrade_cleanup_source_cache y >/dev/null
[[ -f "${LNMP_SOURCE_CACHE_ROOT}/artifact" ]] \
    || fail 'source-cache dry-run must not remove artifacts'
_upgrade_cleanup_source_cache n >/dev/null
[[ ! -e "$LNMP_SOURCE_CACHE_ROOT" ]] \
    || fail 'source-cache cleanup must remove transient artifacts'
mkdir -p "${LNMP_SOURCE_CACHE_ROOT}/custom-module"
Nginx_Modules_Options="--add-module=${LNMP_SOURCE_CACHE_ROOT}/custom-module"
_upgrade_cleanup_source_cache n >/dev/null
[[ -d "$LNMP_SOURCE_CACHE_ROOT" ]] \
    || fail 'source cache referenced by a configured Nginx module must be preserved'
rm -rf "$LNMP_SOURCE_CACHE_ROOT"
Nginx_Modules_Options=''
unset LNMP_SOURCE_CACHE_ROOT

LNMP_UPGRADE_BACKUP_DIR="${TEST_TMP}/backups"
LNMP_UPGRADE_BACKUP_DAYS=0
LNMP_UPGRADE_BACKUP_RETAIN=3
mkdir -p "$LNMP_UPGRADE_BACKUP_DIR"
BACKUP_ROOT=$(_upgrade_backup_root nginx)
assert_eq pending "$(cat "${BACKUP_ROOT}/status")" 'new rollback backup lifecycle'
assert_eq 700 "$(_upgrade_file_metadata "$BACKUP_ROOT" | cut -d: -f1)" \
    'rollback backup directory mode'
assert_eq 600 "$(_upgrade_file_metadata "${BACKUP_ROOT}/status" | cut -d: -f1)" \
    'rollback backup status mode'
_upgrade_mark_backup "$BACKUP_ROOT" completed
for i in 1 2 3 4 5; do
    mkdir "${LNMP_UPGRADE_BACKUP_DIR}/2020010100000${i}-nginx-test"
    printf 'completed\n' > "${LNMP_UPGRADE_BACKUP_DIR}/2020010100000${i}-nginx-test/status"
    touch -t 202001010000 "${LNMP_UPGRADE_BACKUP_DIR}/2020010100000${i}-nginx-test"
done
mkdir "${LNMP_UPGRADE_BACKUP_DIR}/20200101000006-nginx-pending"
printf 'pending\n' > "${LNMP_UPGRADE_BACKUP_DIR}/20200101000006-nginx-pending/status"
touch -t 202001010000 "${LNMP_UPGRADE_BACKUP_DIR}/20200101000006-nginx-pending"
_upgrade_prune_backups y >/dev/null
assert_eq 6 "$(find "$LNMP_UPGRADE_BACKUP_DIR" -name status -exec grep -l '^completed$' {} \; | wc -l | tr -d ' ')" \
    'backup cleanup dry-run'
_upgrade_prune_backups n >/dev/null
assert_eq 3 "$(find "$LNMP_UPGRADE_BACKUP_DIR" -name status -exec grep -l '^completed$' {} \; | wc -l | tr -d ' ')" \
    'minimum completed rollback retention'
[[ -f "${LNMP_UPGRADE_BACKUP_DIR}/20200101000006-nginx-pending/status" ]] \
    || fail 'pending rollback backup must never be pruned'
unset LNMP_UPGRADE_BACKUP_DIR LNMP_UPGRADE_BACKUP_DAYS LNMP_UPGRADE_BACKUP_RETAIN

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
NGINX_BUILD_OUTPUT='nginx version: nginx/1.30.7 configure arguments: --with-http_ssl_module'

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
_upgrade_preflight_components() { return 0; }
_upgrade_prune_backups() { return 0; }
LNMP_UPGRADE_CLEAN_SOURCES=n
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

source "${REPO_DIR}/conf/bash_completion_lnmp"
COMP_WORDS=(lnmp upgrade '')
COMP_CWORD=2
_lnmp_completion
[[ " ${COMPREPLY[*]} " = *' inspect '* && " ${COMPREPLY[*]} " = *' adopt '* \
    && " ${COMPREPLY[*]} " = *' cleanup '* ]] \
    || fail 'upgrade completion must expose inspect, adopt, and cleanup'
COMP_WORDS=(lnmp upgrade cleanup --)
COMP_CWORD=3
_lnmp_completion
assert_eq '--dry-run' "${COMPREPLY[*]}" 'cleanup option completion'

printf 'upgrade_test: PASS\n'
