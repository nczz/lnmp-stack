#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

source "${REPO_DIR}/versions.conf"
source "${REPO_DIR}/lnmp.conf"
source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/upgrade.sh"
LOG_FILE="${TEST_TMP}/upgrade.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" = "$expected" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

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
unset NGINX_BUILD_OUTPUT REDIS_CLI_BIN REDIS_CONFIG_FILE REDIS_ARGS_FILE

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
_upgrade_validate_nginx_modules() { return 0; }
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
