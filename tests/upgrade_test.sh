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
source "${REPO_DIR}/lib/detect.sh"

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
: > "${DOWNLOAD_ROOT}/resumed"
(
    cur_dir="$DOWNLOAD_ROOT"
    LOG_FILE="${DOWNLOAD_ROOT}/download.log"
    wget() {
        local output='' count continue=n
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -O)
                    output="$2"
                    shift 2
                    ;;
                --continue)
                    continue=y
                    shift
                    ;;
                --header=*)
                    [[ -s "${DOWNLOAD_ROOT}/headers" ]] \
                        || printf '%s\n' "${1#--header=}" > "${DOWNLOAD_ROOT}/headers"
                    shift
                    ;;
                *) shift ;;
            esac
        done
        [[ "$continue" = y ]] || return 2
        count=$(<"${DOWNLOAD_ROOT}/attempts")
        [[ ! -s "$output" ]] || printf 'resumed\n' >> "${DOWNLOAD_ROOT}/resumed"
        ((count += 1))
        printf '%s\n' "$count" > "${DOWNLOAD_ROOT}/attempts"
        if (( count < 3 )); then
            printf 'partial-%s\n' "$count" >> "$output"
            return 1
        fi
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
assert_eq $'resumed\nresumed' "$(<"${DOWNLOAD_ROOT}/resumed")" \
    'interrupted downloads resume their partial artifact'
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

PHP_EXTENSION_DIR_PROBE="${TEST_TMP}/php-extension-dir-probe"
cat > "$PHP_EXTENSION_DIR_PROBE" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " = *' -n '* ]]; then
    printf '/usr/local/php/lib/php/extensions/no-debug-non-zts-20240924'
else
    printf '/opt/legacy-php/lib/php/extensions/no-debug-non-zts-20230831'
fi
EOF
chmod 0700 "$PHP_EXTENSION_DIR_PROBE"
assert_eq '/opt/legacy-php/lib/php/extensions/no-debug-non-zts-20230831' \
    "$(_upgrade_php_extension_dir "$PHP_EXTENSION_DIR_PROBE" effective)" \
    'effective extension directory probe'
assert_eq '/usr/local/php/lib/php/extensions/no-debug-non-zts-20240924' \
    "$(_upgrade_php_extension_dir "$PHP_EXTENSION_DIR_PROBE" compiled)" \
    'compiled extension directory probe'
if _upgrade_php_extension_dir "$PHP_EXTENSION_DIR_PROBE" invalid >/dev/null 2>&1; then
    fail 'invalid PHP extension directory probe source must fail'
fi


PHP_UPGRADE_CONFIG_ROOT="${TEST_TMP}/php-config"
mkdir -p "${PHP_UPGRADE_CONFIG_ROOT}/php.d"
cat > "${PHP_UPGRADE_CONFIG_ROOT}/php.ini" <<'EOF'
extension_dir = "/opt/legacy-php/lib/php/extensions/no-debug-non-zts-20230831" ; effective ABI
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
PHP_UPGRADE_OLD_EXT_DIR=/opt/legacy-php/lib/php/extensions/no-debug-non-zts-20230831
PHP_UPGRADE_NEW_EXT_DIR=/usr/local/php/lib/php/extensions/no-debug-non-zts-20240924
_upgrade_migrate_php_extension_dir "$PHP_CONFIG_LIVE" "${PHP_CONFIG_LIVE}/php.d" \
    "$PHP_UPGRADE_OLD_EXT_DIR" "$PHP_UPGRADE_NEW_EXT_DIR"
assert_eq \
    'extension_dir = "/usr/local/php/lib/php/extensions/no-debug-non-zts-20240924" ; effective ABI' \
    "$(grep '^extension_dir' "${PHP_CONFIG_LIVE}/php.ini")" \
    'PHP extension effective ABI directory migration across installation prefixes'
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
unset PHP_UPGRADE_OLD_EXT_DIR PHP_UPGRADE_NEW_EXT_DIR

PHP_EXTENSION_STORE="${TEST_TMP}/php-extension-store"
PHP_EXTENSION_OLD="${TEST_TMP}/php-extension-old"
PHP_EXTENSION_ALIAS="${TEST_TMP}/php-extension-alias"
PHP_EXTENSION_COPY="${TEST_TMP}/php-extension-copy"
mkdir -p "$PHP_EXTENSION_STORE"
printf 'extension binary\n' > "${PHP_EXTENSION_STORE}/custom.so"
ln -s "$PHP_EXTENSION_STORE" "$PHP_EXTENSION_OLD"
ln -s "$PHP_EXTENSION_STORE" "$PHP_EXTENSION_ALIAS"
_upgrade_copy_php_extension_dir "$PHP_EXTENSION_OLD" "$PHP_EXTENSION_ALIAS" \
    || fail 'same-ABI extension preservation must accept aliases of the same directory'
_upgrade_copy_php_extension_dir "$PHP_EXTENSION_OLD" "$PHP_EXTENSION_COPY" \
    || fail 'same-ABI extension preservation must copy distinct directories'
cmp -s "${PHP_EXTENSION_STORE}/custom.so" "${PHP_EXTENSION_COPY}/custom.so" \
    || fail 'same-ABI extension preservation must retain custom extension binaries'

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

(
    _upgrade_php_config_root() { printf '/usr/local/php/etc'; }
    _upgrade_php_scan_dir() { printf '/usr/local/php/etc/php.d'; }
    _upgrade_php_layout_supported
) || fail 'project-managed PHP layout must be upgradeable'
(
    _upgrade_php_config_root() { printf '/usr/local/php-8.2.35/etc'; }
    _upgrade_php_scan_dir() { printf '/usr/local/php-8.2.35/conf.d'; }
    _upgrade_php_layout_supported
) || fail 'versioned legacy PHP layout must be upgradeable'
if (
    _upgrade_php_config_root() { printf '/opt/php/etc'; }
    _upgrade_php_scan_dir() { printf '/opt/php/etc/conf.d'; }
    _upgrade_php_layout_supported
) >/dev/null 2>&1; then
    fail 'nonstandard PHP config roots must require an explicit migration'
fi


PROC_ROOT="${TEST_TMP}/proc"
EXPECTED_SERVICE_BIN="${TEST_TMP}/expected-nginx"
mkdir -p "${PROC_ROOT}/1234"
touch "$EXPECTED_SERVICE_BIN"
EXPECTED_SERVICE_BIN="$(readlink -f "$EXPECTED_SERVICE_BIN")"
ln -s "$EXPECTED_SERVICE_BIN" "${PROC_ROOT}/1234/exe"
LNMP_UPGRADE_PROC_ROOT="$PROC_ROOT"
LNMP_NGINX_PID_FILE="${TEST_TMP}/nginx.pid"
printf '1234\n' > "$LNMP_NGINX_PID_FILE"
systemctl() {
    fail 'Nginx process ownership must not depend on systemd'
}
_upgrade_service_owned nginx "$EXPECTED_SERVICE_BIN" \
    || fail 'live Nginx master using the expected binary must pass preflight'
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
unset LNMP_UPGRADE_PROC_ROOT LNMP_NGINX_PID_FILE
ATOMIC_SOURCE="${TEST_TMP}/atomic-source"
ATOMIC_DEST="${TEST_TMP}/atomic-destination"
printf 'old\n' > "$ATOMIC_DEST"
printf 'new\n' > "$ATOMIC_SOURCE"
_upgrade_install_file_atomically "$ATOMIC_SOURCE" "$ATOMIC_DEST" \
    || fail 'atomic file activation must succeed'
assert_eq new "$(cat "$ATOMIC_DEST")" 'atomic file activation content'
[[ ! -e "${ATOMIC_DEST}.lnmp-new" ]] \
    || fail 'atomic file activation must consume its staged path'
SSL_SAFE_DIR="${TEST_TMP}/nginx-ssl-safe"
mkdir -p "$SSL_SAFE_DIR"
cat > "${SSL_SAFE_DIR}/site.conf" <<'EOF'
server
{
    listen 80;
    listen 443 ssl http2;
    location / {
        try_files $uri =404;
    }
    ssl on;
}
server {
    listen 80;
    ssl off;
}
EOF
chmod 0640 "${SSL_SAFE_DIR}/site.conf"
_upgrade_nginx_migrate_redundant_ssl_on "$SSL_SAFE_DIR" \
    || fail 'redundant legacy Nginx SSL directive must migrate'
if grep -Eq '^[[:space:]]*ssl[[:space:]]+(on|off)' "${SSL_SAFE_DIR}/site.conf"; then
    fail 'legacy Nginx SSL directive must be removed'
fi
assert_eq 640 "$(_upgrade_file_metadata "${SSL_SAFE_DIR}/site.conf" | cut -d: -f1)" \
    'Nginx SSL migration file mode'

SSL_UNSAFE_DIR="${TEST_TMP}/nginx-ssl-unsafe"
mkdir -p "$SSL_UNSAFE_DIR"
cat > "${SSL_UNSAFE_DIR}/site.conf" <<'EOF'
server {
    listen 443;
    ssl on;
}
EOF
cp "${SSL_UNSAFE_DIR}/site.conf" "${SSL_UNSAFE_DIR}/site.before"
if _upgrade_nginx_migrate_redundant_ssl_on "$SSL_UNSAFE_DIR" >/dev/null 2>&1; then
    fail 'non-redundant legacy Nginx SSL directive must block migration'
fi
cmp -s "${SSL_UNSAFE_DIR}/site.before" "${SSL_UNSAFE_DIR}/site.conf" \
    || fail 'blocked Nginx SSL migration must not change configuration'
SSL_ACTIVE_DIR="${TEST_TMP}/nginx-ssl-active"
mkdir -p "${SSL_ACTIVE_DIR}/bak"
cp "${SSL_SAFE_DIR}/site.conf" "${SSL_ACTIVE_DIR}/site.conf"
cat >> "${SSL_ACTIVE_DIR}/site.conf" <<'EOF'
server {
    listen 443 ssl;
    ssl on;
}
EOF
cp "${SSL_UNSAFE_DIR}/site.before" "${SSL_ACTIVE_DIR}/bak/inactive.conf"
printf '%s\n' "${SSL_ACTIVE_DIR}/site.conf" > "${SSL_ACTIVE_DIR}/active.manifest"
_upgrade_nginx_migrate_redundant_ssl_on "$SSL_ACTIVE_DIR" \
    "${SSL_ACTIVE_DIR}/active.manifest" \
    || fail 'active Nginx configuration migration must ignore inactive backups'
if grep -Eq '^[[:space:]]*ssl[[:space:]]+on' "${SSL_ACTIVE_DIR}/site.conf"; then
    fail 'active Nginx legacy SSL directive must be removed'
fi
grep -Eq '^[[:space:]]*ssl[[:space:]]+on' "${SSL_ACTIVE_DIR}/bak/inactive.conf" \
    || fail 'inactive Nginx backup must remain unchanged'



OS_VER=18.04
OS_CODENAME=bionic
INSTALL_TARGET=nginx
LNMP_UPGRADE_MODE=1
LNMP_UPGRADE_OS_SAFE_COMPONENTS=1
LNMP_ALLOW_UNSUPPORTED_OS_UPGRADE=1
check_os_support >/dev/null
if (LNMP_UPGRADE_MODE=0; check_os_support) >/dev/null 2>&1; then
    fail 'unsupported OS override must not permit a fresh installation'
fi
# shellcheck disable=SC2030  # The rejected value is intentionally isolated from the parent test shell.
if (LNMP_UPGRADE_OS_SAFE_COMPONENTS=0; check_os_support) >/dev/null 2>&1; then
    fail 'unsupported OS override must not permit non-Nginx/PHP upgrade components'
fi
unset LNMP_ALLOW_UNSUPPORTED_OS_UPGRADE LNMP_UPGRADE_MODE LNMP_UPGRADE_OS_SAFE_COMPONENTS INSTALL_TARGET


LNMP_UPGRADE_FREE_KB=5242880
_upgrade_validate_capacity
set +e
(LNMP_UPGRADE_FREE_KB=1048576; _upgrade_validate_capacity) >/dev/null 2>&1
rc=$?
set -e
assert_eq 69 "$rc" 'insufficient upgrade capacity exit code'
unset LNMP_UPGRADE_FREE_KB

assert_eq 0 \
    "$(LNMP_UPGRADE_BUILD_MEMORY_MB=4096 _upgrade_required_build_swap_mb)" \
    'sufficient PHP build memory needs no temporary swap'
assert_eq 2596 \
    "$(LNMP_UPGRADE_BUILD_MEMORY_MB=1500 _upgrade_required_build_swap_mb)" \
    'low-memory PHP build temporary swap size'

BUILD_SWAP_BIN="${TEST_TMP}/build-swap-bin"
BUILD_SWAP_FILE="${TEST_TMP}/state/upgrade-build.swap"
BUILD_SWAP_ACTIVE="${TEST_TMP}/active-swaps"
BUILD_SWAP_CALLS="${TEST_TMP}/build-swap-calls"
mkdir -p "$BUILD_SWAP_BIN"
: > "$BUILD_SWAP_ACTIVE"
: > "$BUILD_SWAP_CALLS"
cat > "${BUILD_SWAP_BIN}/fallocate" <<'EOF'
#!/usr/bin/env bash
printf 'fallocate %s\n' "$*" >> "$BUILD_SWAP_CALLS"
: > "${@: -1}"
EOF
cat > "${BUILD_SWAP_BIN}/mkswap" <<'EOF'
#!/usr/bin/env bash
printf 'mkswap %s\n' "$*" >> "$BUILD_SWAP_CALLS"
EOF
cat > "${BUILD_SWAP_BIN}/swapon" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$BUILD_SWAP_ACTIVE"
printf 'swapon %s\n' "$*" >> "$BUILD_SWAP_CALLS"
EOF
cat > "${BUILD_SWAP_BIN}/swapoff" <<'EOF'
#!/usr/bin/env bash
grep -qx "$1" "$BUILD_SWAP_ACTIVE" || exit 96
: > "$BUILD_SWAP_ACTIVE"
printf 'swapoff %s\n' "$*" >> "$BUILD_SWAP_CALLS"
EOF
chmod +x "${BUILD_SWAP_BIN}/"{fallocate,mkswap,swapon,swapoff}
export BUILD_SWAP_ACTIVE BUILD_SWAP_CALLS
PATH="${BUILD_SWAP_BIN}:${PATH}" \
LNMP_UPGRADE_BUILD_MEMORY_MB=3500 \
LNMP_UPGRADE_BUILD_SWAP_FILE="$BUILD_SWAP_FILE" \
LNMP_UPGRADE_ACTIVE_SWAPS_FILE="$BUILD_SWAP_ACTIVE" \
LNMP_UPGRADE_FREE_KB=5242880 \
    _upgrade_prepare_build_swap php
[[ -f "$BUILD_SWAP_FILE" ]] || fail 'low-memory PHP build must create temporary swap'
assert_eq 600 "$(_upgrade_file_metadata "$BUILD_SWAP_FILE" | cut -d: -f1)" \
    'temporary PHP build swap mode'
grep -q '^swapon ' "$BUILD_SWAP_CALLS" \
    || fail 'low-memory PHP build must activate temporary swap'
PATH="${BUILD_SWAP_BIN}:${PATH}" \
LNMP_UPGRADE_ACTIVE_SWAPS_FILE="$BUILD_SWAP_ACTIVE" \
    _upgrade_cleanup_build_swap n "$BUILD_SWAP_FILE"
[[ ! -e "$BUILD_SWAP_FILE" ]] || fail 'temporary PHP build swap must be removed'
grep -q '^swapoff ' "$BUILD_SWAP_CALLS" \
    || fail 'temporary PHP build swap must be deactivated before removal'
unset BUILD_SWAP_ACTIVE BUILD_SWAP_CALLS _UPGRADE_BUILD_SWAP_FILE

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
assert_eq 8.3.37 "$(_upgrade_target_version php)" 'PHP 8.3 patch target'
RUNTIME[php]=8.2.35
assert_eq 8.2.36 "$(_upgrade_target_version php)" 'PHP 8.2 patch target'
RUNTIME[php]=8.5.12
assert_eq 8.5.13 "$(_upgrade_target_version php)" 'PHP 8.5 patch target'
RUNTIME[php]=8.3.15
Enable_Nginx_Openssl=n
assert_eq REVIEW "$(_upgrade_component_status nginx)" 'v1.3 Nginx transition'
assert_eq OUTDATED "$(_upgrade_component_status php)" 'historical PHP release-series patch transition'
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
_upgrade_load_build_libraries() {
    LOADED_TARGET="$INSTALL_TARGET"
    # shellcheck disable=SC2031  # The negative gate test mutates this variable only in an isolated subshell.
    LOADED_OS_SAFE="$LNMP_UPGRADE_OS_SAFE_COMPONENTS"
}
upgrade_plan() { return 0; }
_upgrade_preflight_components() { return 0; }
LNMP_UPGRADE_CLEAN_SOURCES=n
LNMP_UPGRADE_BUILD_MEMORY_MB=4096
LNMP_UPGRADE_BACKUP_DIR="${TEST_TMP}/apply-backups"
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
assert_eq 'php' "$LOADED_TARGET" 'PHP-only upgrade architecture target'

APPLIED=()
upgrade_apply nginx php >/dev/null
assert_eq 'nginx php' "${APPLIED[*]}" 'combined Nginx/PHP selection'
assert_eq 1 "$LOADED_OS_SAFE" \
    'combined Nginx/PHP selection remains architecture and legacy-OS safe'

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
unset LNMP_UPGRADE_BUILD_MEMORY_MB

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
