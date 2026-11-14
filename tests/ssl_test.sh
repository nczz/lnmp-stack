#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" = "$expected" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_line() {
    local line="$1" file="$2" label="$3"
    grep -Fqx -- "$line" "$file" || fail "${label}: missing '${line}'"
}

file_mode() {
    local file="$1" mode
    if mode=$(stat -c '%a' "$file" 2>/dev/null); then
        printf '%s' "$mode"
    else
        stat -f '%Lp' "$file"
    fi
}

ACME_HOME="${TEST_TMP}/acme"
SSL_DIR="${TEST_TMP}/ssl"
VHOST_DIR="${TEST_TMP}/vhost"
WEBROOT="${TEST_TMP}/www/http.example.com"
ACME_CALL_LOG="${TEST_TMP}/acme-calls"
DNS_AUTH_MARKER="${TEST_TMP}/dns-auth-ok"
SYSTEMCTL_BIN="${TEST_TMP}/systemctl"
NGINX_BIN="${TEST_TMP}/nginx"
mkdir -p "$ACME_HOME/dnsapi" "$SSL_DIR" "$VHOST_DIR" "$WEBROOT"
for hook in dns_cf dns_aws dns_ali dns_dp; do
    : > "$ACME_HOME/dnsapi/${hook}.sh"
done

cat > "$ACME_HOME/acme.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'CALL\n'
    for arg in "$@"; do
        printf 'ARG=%s\n' "$arg"
    done
} >> "$ACME_CALL_LOG"

is_dns=n
dns_provider=''
previous=''
for arg in "$@"; do
    if [[ "$previous" = '--dns' ]]; then
        dns_provider="$arg"
    fi
    [[ "$arg" = '--dns' ]] && is_dns=y
    previous="$arg"
done

case " $* " in
    *' --issue '*)
        if [[ "$is_dns" = y ]]; then
            case "$dns_provider" in
                dns_cf)  [[ "${CF_Token:-}" = 'test-cloudflare-token' ]] || exit 86 ;;
                dns_aws) [[ "${AWS_ACCESS_KEY_ID:-}" = 'test-aws-key' && "${AWS_SECRET_ACCESS_KEY:-}" = 'test-aws-secret' ]] || exit 89 ;;
                dns_ali) [[ "${Ali_Key:-}" = 'test-ali-key' && "${Ali_Secret:-}" = 'test-ali-secret' ]] || exit 90 ;;
                dns_dp)  [[ "${DP_Id:-}" = 'test-dp-id' && "${DP_Key:-}" = 'test-dp-key' ]] || exit 91 ;;
                *) exit 92 ;;
            esac
            printf '%s\n' "$dns_provider" > "$DNS_AUTH_MARKER"
        fi
        mkdir -p "$ACME_HOME/example.com_ecc"
        printf 'SAVED_TEST=value\n' > "$ACME_HOME/account.conf"
        printf 'Le_Domain=example.com\n' > "$ACME_HOME/example.com_ecc/example.com.conf"
        chmod 0644 "$ACME_HOME/account.conf" "$ACME_HOME/example.com_ecc/example.com.conf"
        exit "${FAKE_ACME_ISSUE_RC:-0}"
        ;;
    *' --install-cert '*)
        [[ -z "${CF_Token:-}${CF_Account_ID:-}${CF_Zone_ID:-}" ]] || exit 88
        [[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}${AWS_DNS_SLOWRATE:-}" ]] || exit 93
        [[ -z "${Ali_Key:-}${Ali_Secret:-}${DP_Id:-}${DP_Key:-}" ]] || exit 94
        key_file=''
        fullchain_file=''
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --key-file) key_file="$2"; shift 2 ;;
                --fullchain-file) fullchain_file="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -n "$key_file" && -n "$fullchain_file" ]] || exit 87
        mkdir -p "$(dirname "$key_file")" "$(dirname "$fullchain_file")"
        printf 'test-key\n' > "$key_file"
        printf 'test-fullchain\n' > "$fullchain_file"
        ;;
    *' --renew-all '*|*' --renew '*) exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$SYSTEMCTL_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$NGINX_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ACME_HOME/acme.sh" "$SYSTEMCTL_BIN" "$NGINX_BIN"
export ACME_CALL_LOG DNS_AUTH_MARKER

run_ssl() {
    env LNMP_ASSUME_YES=1 \
        ACME_HOME="$ACME_HOME" SSL_DIR="$SSL_DIR" VHOST_DIR="$VHOST_DIR" \
        SYSTEMCTL_BIN="$SYSTEMCTL_BIN" NGINX_BIN="$NGINX_BIN" \
        bash "${REPO_DIR}/tools/ssl.sh" "$@"
}

CREDENTIALS="${TEST_TMP}/cloudflare.env"
printf 'CF_Token=test-cloudflare-token\nCF_Account_ID=test-account\n' > "$CREDENTIALS"
chmod 0600 "$CREDENTIALS"
DNS_OUTPUT="${TEST_TMP}/dns-output"
run_ssl install example.com --domains '*.example.com' \
    --challenge dns --dns-provider dns_cf --dns-credentials "$CREDENTIALS" \
    --dns-sleep 30 >"$DNS_OUTPUT" 2>&1
assert_line 'ARG=--dns' "$ACME_CALL_LOG" 'DNS-01 issue mode'
assert_line 'ARG=dns_cf' "$ACME_CALL_LOG" 'Cloudflare provider'
assert_line 'ARG=*.example.com' "$ACME_CALL_LOG" 'wildcard SAN'
assert_line 'ARG=--dnssleep' "$ACME_CALL_LOG" 'DNS propagation override'
assert_line 'ARG=30' "$ACME_CALL_LOG" 'DNS propagation seconds'
if grep -Fqx 'ARG=-w' "$ACME_CALL_LOG"; then
    fail 'DNS-01 must not pass a webroot challenge'
fi
[[ -f "$DNS_AUTH_MARKER" ]] || fail 'DNS provider credentials did not reach acme.sh'
[[ -s "$SSL_DIR/example.com/key.pem" && -s "$SSL_DIR/example.com/fullchain.pem" ]] \
    || fail 'DNS-01 certificate files were not installed'
assert_eq 700 "$(file_mode "$ACME_HOME")" 'ACME home permissions'
assert_eq 600 "$(file_mode "$ACME_HOME/account.conf")" 'ACME account permissions'
assert_eq 600 "$(file_mode "$ACME_HOME/example.com_ecc/example.com.conf")" \
    'ACME domain permissions'
if grep -Fq 'test-cloudflare-token' "$DNS_OUTPUT"; then
    fail 'DNS credential leaked to command output'
fi

AWS_CREDENTIALS="${TEST_TMP}/route53.env"
ALI_CREDENTIALS="${TEST_TMP}/alidns.env"
DP_CREDENTIALS="${TEST_TMP}/dnspod.env"
printf 'AWS_ACCESS_KEY_ID=test-aws-key\nAWS_SECRET_ACCESS_KEY=test-aws-secret\n' > "$AWS_CREDENTIALS"
printf 'Ali_Key=test-ali-key\nAli_Secret=test-ali-secret\n' > "$ALI_CREDENTIALS"
printf 'DP_Id=test-dp-id\nDP_Key=test-dp-key\n' > "$DP_CREDENTIALS"
chmod 0600 "$AWS_CREDENTIALS" "$ALI_CREDENTIALS" "$DP_CREDENTIALS"
for provider_case in \
    "dns_aws aws.example.com ${AWS_CREDENTIALS}" \
    "dns_ali ali.example.com ${ALI_CREDENTIALS}" \
    "dns_dp dp.example.com ${DP_CREDENTIALS}"; do
    read -r provider domain credentials <<< "$provider_case"
    : > "$ACME_CALL_LOG"
    run_ssl install "$domain" --challenge dns --dns-provider "$provider" \
        --dns-credentials "$credentials" --no-vhost-update \
        >"${TEST_TMP}/${provider}-output" 2>&1
    assert_line "ARG=${provider}" "$ACME_CALL_LOG" "${provider} issue hook"
    assert_eq "$provider" "$(cat "$DNS_AUTH_MARKER")" "${provider} credentials"
done

: > "$ACME_CALL_LOG"
cat > "$VHOST_DIR/http.example.com.conf" <<EOF
server {
    listen 80;
    server_name http.example.com;
    root ${WEBROOT};
    index index.html;
}
EOF
HTTP_OUTPUT="${TEST_TMP}/http-output"
run_ssl install http.example.com --webroot "$WEBROOT" --no-vhost-update \
    >"$HTTP_OUTPUT" 2>&1
assert_line 'ARG=-w' "$ACME_CALL_LOG" 'HTTP-01 remains the default'
assert_line "ARG=${WEBROOT}" "$ACME_CALL_LOG" 'HTTP-01 webroot'
if grep -Fqx 'ARG=--dns' "$ACME_CALL_LOG"; then
    fail 'HTTP-01 unexpectedly selected a DNS provider'
fi
assert_line 'ARG=--server' "$ACME_CALL_LOG" 'explicit ACME server option'
assert_line 'ARG=letsencrypt' "$ACME_CALL_LOG" "Let's Encrypt remains the default CA"

set +e
run_ssl install missing.example.com --challenge dns --dns-provider dns_cf \
    >"${TEST_TMP}/missing-credentials" 2>&1
rc=$?
set -e
assert_eq 69 "$rc" 'missing DNS credentials exit code'
[[ "$(cat "${TEST_TMP}/missing-credentials")" = *'CF_Token'* ]] \
    || fail 'missing DNS credential diagnostic must name CF_Token'

chmod 0644 "$CREDENTIALS"
set +e
run_ssl install insecure.example.com --challenge dns --dns-provider dns_cf \
    --dns-credentials "$CREDENTIALS" >"${TEST_TMP}/insecure-credentials" 2>&1
rc=$?
set -e
assert_eq 64 "$rc" 'insecure DNS credential file exit code'
chmod 0600 "$CREDENTIALS"
UNKNOWN_CREDENTIALS="${TEST_TMP}/unknown-cloudflare.env"
printf 'CF_Key=not-supported\n' > "$UNKNOWN_CREDENTIALS"
chmod 0600 "$UNKNOWN_CREDENTIALS"
set +e
run_ssl install unknown-key.example.com --challenge dns --dns-provider dns_cf \
    --dns-credentials "$UNKNOWN_CREDENTIALS" >"${TEST_TMP}/unknown-credential" 2>&1
rc=$?
set -e
assert_eq 64 "$rc" 'unknown DNS credential key exit code'
[[ "$(cat "${TEST_TMP}/unknown-credential")" = *'not allowed for dns_cf'* ]] \
    || fail 'unknown DNS credential diagnostic must name the provider'

set +e
run_ssl install wildcard.example.com --domains '*.example.com' \
    >"${TEST_TMP}/http-wildcard" 2>&1
rc=$?
set -e
assert_eq 64 "$rc" 'HTTP-01 wildcard rejection'

set +e
run_ssl install provider.example.com --challenge dns --dns-provider dns_unknown \
    >"${TEST_TMP}/invalid-provider" 2>&1
rc=$?
set -e
assert_eq 64 "$rc" 'unsupported DNS provider exit code'

set +e
run_ssl install conflict.example.com --challenge dns --dns-provider dns_cf \
    --dns-credentials "$CREDENTIALS" --webroot /tmp/conflict \
    >"${TEST_TMP}/challenge-conflict" 2>&1
rc=$?
set -e
assert_eq 64 "$rc" 'DNS/webroot conflict exit code'

: > "$ACME_CALL_LOG"
run_ssl renew >"${TEST_TMP}/renew-output" 2>&1
assert_line 'ARG=--renew-all' "$ACME_CALL_LOG" 'saved DNS renewal path'

VHOST_TEST_DIR="${TEST_TMP}/vhost-integration"
mkdir -p "${VHOST_TEST_DIR}/conf" "${VHOST_TEST_DIR}/rewrite" "${VHOST_TEST_DIR}/www"
: > "${VHOST_TEST_DIR}/rewrite/none.conf"
: > "$ACME_CALL_LOG"
env LNMP_ASSUME_YES=1 \
    VHOST_DIR="${VHOST_TEST_DIR}/conf" \
    WEBROOT_BASE="${VHOST_TEST_DIR}/www" \
    REWRITE_DIR="${VHOST_TEST_DIR}/rewrite" \
    NGINX_BIN="$NGINX_BIN" SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
    WEB_OWNER="$(id -u):$(id -g)" \
    ACME_HOME="$ACME_HOME" SSL_DIR="$SSL_DIR" \
    LNMP_BACKUP_ROOT="${TEST_TMP}/backups" \
    bash "${REPO_DIR}/tools/vhost.sh" add vhost.example.com \
        --domains '*.vhost.example.com' --rewrite none --ssl \
        --challenge dns --dns-provider dns_cf --dns-credentials "$CREDENTIALS" \
        --dns-sleep 45 >"${TEST_TMP}/vhost-output" 2>&1
assert_line 'ARG=--issue' "$ACME_CALL_LOG" 'vhost SSL install dispatch'
assert_line 'ARG=--dns' "$ACME_CALL_LOG" 'vhost challenge option'
assert_line 'ARG=dns_cf' "$ACME_CALL_LOG" 'vhost provider value'
assert_line 'ARG=*.vhost.example.com' "$ACME_CALL_LOG" 'vhost wildcard SAN'
assert_line 'ARG=--dnssleep' "$ACME_CALL_LOG" 'vhost DNS sleep option'
assert_line 'ARG=45' "$ACME_CALL_LOG" 'vhost DNS sleep value'
if grep -Fqx -- 'ARG=-w' "$ACME_CALL_LOG"; then
    fail 'DNS-01 vhost integration must not pass HTTP webroot arguments'
fi
grep -Fq 'server_name vhost.example.com *.vhost.example.com;' \
    "${VHOST_TEST_DIR}/conf/vhost.example.com.conf" \
    || fail 'wildcard DNS-01 alias missing from generated vhost'
grep -Fq 'listen 443 ssl;' "${VHOST_TEST_DIR}/conf/vhost.example.com.conf" \
    || fail 'DNS-01 vhost integration did not install the HTTPS server block'
assert_eq 2 \
    "$(grep -Fc 'location ^~ /.well-known/acme-challenge/' "${VHOST_TEST_DIR}/conf/vhost.example.com.conf")" \
    'new vhost HTTP and HTTPS ACME challenge locations'
if grep -Fq 'return 301 https' "${VHOST_TEST_DIR}/conf/vhost.example.com.conf"; then
    fail 'vhost without --redirect must not force an HTTP redirect'
fi
: > "$ACME_CALL_LOG"
env LNMP_ASSUME_YES=1 \
    VHOST_DIR="${VHOST_TEST_DIR}/conf" \
    WEBROOT_BASE="${VHOST_TEST_DIR}/www" \
    REWRITE_DIR="${VHOST_TEST_DIR}/rewrite" \
    NGINX_BIN="$NGINX_BIN" SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
    WEB_OWNER="$(id -u):$(id -g)" \
    ACME_HOME="$ACME_HOME" SSL_DIR="$SSL_DIR" \
    LNMP_BACKUP_ROOT="${TEST_TMP}/backups" \
    bash "${REPO_DIR}/tools/vhost.sh" add redirect.example.com \
        --rewrite none --ssl --challenge dns --dns-provider dns_cf \
        --dns-credentials "$CREDENTIALS" --redirect \
        >"${TEST_TMP}/redirect-vhost-output" 2>&1
REDIRECT_CONF="${VHOST_TEST_DIR}/conf/redirect.example.com.conf"
grep -Fq "    if (\$request_uri !~ \"^/\\.well-known/acme-challenge/\") {" \
    "$REDIRECT_CONF" \
    || fail '--redirect must exempt the HTTP-01 challenge before returning 301'
assert_eq 2 "$(grep -Fc 'location ^~ /.well-known/acme-challenge/' "$REDIRECT_CONF")" \
    'HTTP and HTTPS ACME challenge locations'

SELF_CONF="${VHOST_TEST_DIR}/conf/self.example.com.conf"
SELF_WEBROOT="${VHOST_TEST_DIR}/www/self.example.com"
mkdir -p "$SELF_WEBROOT"
cat > "$SELF_CONF" <<EOF
server {
    listen 80;
    server_name self.example.com www.self.example.com;
    root ${SELF_WEBROOT};
    index index.html;
}
EOF
if ! env LNMP_ASSUME_YES=1 \
        ACME_HOME="$ACME_HOME" SSL_DIR="$SSL_DIR" VHOST_DIR="${VHOST_TEST_DIR}/conf" \
        NGINX_BIN="$NGINX_BIN" SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
        LNMP_BACKUP_ROOT="${TEST_TMP}/backups" \
        bash "${REPO_DIR}/tools/ssl.sh" self self.example.com \
        >"${TEST_TMP}/self-output" 2>&1; then
    cat "${TEST_TMP}/self-output" >&2
    fail 'self-signed certificate command failed'
fi
assert_eq 2 "$(grep -Fc 'server_name self.example.com www.self.example.com;' "$SELF_CONF")" \
    'self-signed HTTPS aliases'
openssl x509 -in "${SSL_DIR}/self.example.com/fullchain.pem" -noout -ext subjectAltName \
    | grep -Fq 'DNS:self.example.com, DNS:www.self.example.com' \
    || fail 'self-signed certificate SANs must include vhost aliases'

LEGACY_CONF="${VHOST_TEST_DIR}/conf/legacy.example.com.conf"
cat > "$LEGACY_CONF" <<'EOF'
server {
    listen 80;
    server_name legacy.example.com;
    root /tmp/legacy;
    index index.html;

    return 301 https://$host$request_uri;

    location ^~ /.well-known/acme-challenge/ {
        allow all;
    }
}
server {
    listen 443 ssl;
    server_name legacy.example.com;
    root /tmp/legacy;
    index index.html;

    location ~ /\. {
        deny all;
    }
}
EOF
env LNMP_ASSUME_YES=1 \
    ACME_HOME="$ACME_HOME" SSL_DIR="$SSL_DIR" VHOST_DIR="${VHOST_TEST_DIR}/conf" \
    NGINX_BIN="$NGINX_BIN" SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
    LNMP_BACKUP_ROOT="${TEST_TMP}/backups" \
    bash "${REPO_DIR}/tools/ssl.sh" repair >"${TEST_TMP}/repair-output" 2>&1
assert_eq 2 "$(grep -Fc 'location ^~ /.well-known/acme-challenge/' "$LEGACY_CONF")" \
    'legacy HTTP and HTTPS ACME challenge locations'
if grep -Fqx "    return 301 https://\$host\$request_uri;" "$LEGACY_CONF"; then
    fail 'legacy server-level redirect was not migrated'
fi
grep -Fq "    if (\$request_uri !~ \"^/\\.well-known/acme-challenge/\") {" \
    "$LEGACY_CONF" \
    || fail 'legacy redirect migration must exempt the HTTP-01 challenge'
grep -Fq 'Backup:' "${TEST_TMP}/repair-output" \
    || fail 'repair output must identify the migration backup'
cp "$LEGACY_CONF" "${TEST_TMP}/legacy.after"
env LNMP_ASSUME_YES=1 \
    ACME_HOME="$ACME_HOME" SSL_DIR="$SSL_DIR" VHOST_DIR="${VHOST_TEST_DIR}/conf" \
    NGINX_BIN="$NGINX_BIN" SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
    LNMP_BACKUP_ROOT="${TEST_TMP}/backups" \
    bash "${REPO_DIR}/tools/ssl.sh" repair >"${TEST_TMP}/repair-second-output" 2>&1
cmp -s "${TEST_TMP}/legacy.after" "$LEGACY_CONF" \
    || fail 'vhost repair must be idempotent'
grep -Fq 'no migration required' "${TEST_TMP}/repair-second-output" \
    || fail 'idempotent repair must report that no migration is required'

ROLLBACK_CONF="${VHOST_TEST_DIR}/conf/rollback.example.com.conf"
cat > "$ROLLBACK_CONF" <<'EOF'
server {
    listen 80;
    server_name rollback.example.com;
    root /tmp/rollback;
    index index.html;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name rollback.example.com;
    root /tmp/rollback;
    index index.html;
}
EOF
cp "$ROLLBACK_CONF" "${TEST_TMP}/rollback.before"
FAIL_NGINX_BIN="${TEST_TMP}/nginx-fail"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_NGINX_BIN"
chmod +x "$FAIL_NGINX_BIN"
set +e
env LNMP_ASSUME_YES=1 \
    ACME_HOME="$ACME_HOME" SSL_DIR="$SSL_DIR" VHOST_DIR="${VHOST_TEST_DIR}/conf" \
    NGINX_BIN="$FAIL_NGINX_BIN" SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
    LNMP_BACKUP_ROOT="${TEST_TMP}/rollback-backups" \
    bash "${REPO_DIR}/tools/ssl.sh" repair >"${TEST_TMP}/rollback-output" 2>&1
rc=$?
set -e
assert_eq 69 "$rc" 'failed Nginx validation exit code'
cmp -s "${TEST_TMP}/rollback.before" "$ROLLBACK_CONF" \
    || fail 'failed Nginx validation must restore the original vhost'
grep -Fq 'original files were restored' "${TEST_TMP}/rollback-output" \
    || fail 'rollback diagnostic must identify restoration'

printf 'ssl_test: PASS\n'
