#!/usr/bin/env bash
# tools/ssl.sh — SSL certificate management
set -euo pipefail

ACME_HOME="${ACME_HOME:-/usr/local/acme.sh}"
ACME_BIN="${ACME_BIN:-${ACME_HOME}/acme.sh}"
SSL_DIR="${SSL_DIR:-/usr/local/nginx/conf/ssl}"
VHOST_DIR="${VHOST_DIR:-/usr/local/nginx/conf/vhost}"
NGINX_BIN="${NGINX_BIN:-/usr/local/nginx/sbin/nginx}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"

# Load pinned versions, shared config, and helpers.
# Resolve project dir from this script's location so it works installed or in-repo.
_LNMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${_LNMP_DIR}/versions.conf"
[[ -f "${_LNMP_DIR}/lnmp.conf" ]] && source "${_LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${_LNMP_DIR}/lnmp.conf.local" ]] && source "${_LNMP_DIR}/lnmp.conf.local"
[[ -f "${_LNMP_DIR}/lib/common.sh" ]] && source "${_LNMP_DIR}/lib/common.sh"

# Resolve the ACME registration email from multiple sources, in priority order:
#   1. explicit argument   2. ACME_EMAIL env   3. Acme_Email in lnmp.conf.local
# Email is OPTIONAL for acme.sh (Let's Encrypt only uses it for expiry notices),
# so a missing email is NOT a hard failure — we just register without one.
_resolve_acme_email() {
    local email="${1:-}"
    [[ -z "$email" ]] && email="${ACME_EMAIL:-}"
    [[ -z "$email" ]] && email="${Acme_Email:-}"
    printf '%s' "$email"
}

_secure_acme_state() {
    [[ -d "$ACME_HOME" ]] || return 0
    if [[ "$EUID" -eq 0 ]]; then
        chown -R root:root "$ACME_HOME"
    fi
    chmod 0700 "$ACME_HOME"
    local config
    while IFS= read -r -d '' config; do
        chmod 0600 "$config"
    done < <(find "$ACME_HOME" -type f -name '*.conf' -print0)
}

_dns_provider_keys() {
    case "$1" in
        dns_cf)  printf '%s' 'CF_Token CF_Account_ID CF_Zone_ID' ;;
        dns_aws) printf '%s' 'AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DNS_SLOWRATE' ;;
        dns_ali) printf '%s' 'Ali_Key Ali_Secret' ;;
        dns_dp)  printf '%s' 'DP_Id DP_Key' ;;
    esac
}

_dns_provider_hint() {
    case "$1" in
        dns_cf)  printf '%s' 'CF_Token (optional: CF_Account_ID, CF_Zone_ID)' ;;
        dns_aws) printf '%s' 'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or an ECS/EC2 IAM role' ;;
        dns_ali) printf '%s' 'Ali_Key and Ali_Secret' ;;
        dns_dp)  printf '%s' 'DP_Id and DP_Key' ;;
    esac
}

_load_dns_credentials() {
    local provider="$1" file="$2" export_values="${3:-y}"
    local line key value seen=',' allowed
    allowed=" $(_dns_provider_keys "$provider") "
    validate_private_file "DNS credentials file" "$file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] \
            || die_code "$EX_USAGE" "Invalid DNS credentials line; expected NAME=value in ${file}."
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$allowed" == *" ${key} "* ]] \
            || die_code "$EX_USAGE" "Credential '${key}' is not allowed for ${provider}."
        [[ -n "$value" ]] \
            || die_code "$EX_USAGE" "Credential '${key}' must not be empty."
        [[ "$seen" != *",${key},"* ]] \
            || die_code "$EX_USAGE" "Duplicate DNS credential '${key}' in ${file}."
        seen+="${key},"
        if [[ "$export_values" = y ]]; then
            printf -v "$key" '%s' "$value"
            export "${key?}"
        fi
    done < "$file"
}

_require_dns_credentials() {
    local provider="$1"
    case "$provider" in
        dns_cf)
            [[ -n "${CF_Token:-}" ]] \
                || die_code "$EX_UNAVAILABLE" "dns_cf requires CF_Token. Provide it through the environment or a root-only credentials file."
            ;;
        dns_aws)
            if [[ -n "${AWS_ACCESS_KEY_ID:-}" || -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
                [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] \
                    || die_code "$EX_UNAVAILABLE" "dns_aws static credentials require both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
            else
                log_info "dns_aws: no static credentials supplied; acme.sh will require an ECS/EC2 IAM role."
            fi
            ;;
        dns_ali)
            [[ -n "${Ali_Key:-}" && -n "${Ali_Secret:-}" ]] \
                || die_code "$EX_UNAVAILABLE" "dns_ali requires Ali_Key and Ali_Secret."
            ;;
        dns_dp)
            [[ -n "${DP_Id:-}" && -n "${DP_Key:-}" ]] \
                || die_code "$EX_UNAVAILABLE" "dns_dp requires DP_Id and DP_Key."
            ;;
    esac
}

_clear_dns_credentials() {
    local key
    for key in $(_dns_provider_keys "$1"); do
        unset "$key"
    done
}

show_install_usage() {
    cat <<'EOF'
Usage:
  lnmp ssl install <domain> [options]
  ssl.sh install <domain> [options]

Required:
  <domain>                 Primary non-wildcard ASCII/punycode DNS name.

Options:
  --domains "d1 d2"        Additional certificate names. DNS-01 accepts a
                           left-most wildcard such as *.example.com.
  --webroot /path          HTTP-01 webroot; defaults to the existing vhost root.
  --keytype type           ec-256 (default), ec-384, 2048, 3072, or 4096.
  --challenge http|dns     ACME challenge type; default: http.
  --dns-provider name      DNS API hook: dns_cf, dns_aws, dns_ali, or dns_dp.
  --dns-credentials file   Optional root/operator-owned mode-600 NAME=value
                           file. Values are unquoted and never logged.
  --dns-sleep seconds      Optional fixed DNS propagation wait, 1-3600.
  --no-vhost-update       Install certificate files without editing Nginx.
  --help, -h               Show this help.

Rules:
  - HTTP-01 remains the default and requires an existing vhost, shared webroot,
    correct A/AAAA records, and reachable port 80.
  - DNS-01 requires --dns-provider, rejects --webroot, supports wildcard SANs,
    and can issue before a vhost or A/AAAA record exists.
  - dns_cf requires CF_Token; dns_ali requires Ali_Key/Ali_Secret; dns_dp
    requires DP_Id/DP_Key; dns_aws accepts static keys or an ECS/EC2 IAM role.
  - Invalid input exits 64; unavailable client/credentials exit 69; CA,
    provider API, CAA, or propagation failures exit 75.

Examples:
  lnmp --yes ssl install example.com
  lnmp --yes ssl install example.com --challenge dns --dns-provider dns_cf \
    --dns-credentials /etc/lnmp/cloudflare-dns.env
  lnmp --yes ssl install example.com --domains "*.example.com" \
    --challenge dns --dns-provider dns_cf \
    --dns-credentials /etc/lnmp/cloudflare-dns.env
EOF
}

_require_option_arg() {
    local opt="$1" value="${2:-}"
    [[ -n "$value" && "$value" != -* ]] || {
        show_install_usage
        die_code "$EX_USAGE" "Missing value for ${opt}."
    }
}


_ensure_acme() {
    local force="${2:-n}"
    if [[ -s "$ACME_BIN" && "$force" != 'y' ]]; then
        _secure_acme_state
        return 0
    fi

    echo "Installing pinned acme.sh ${ACME_SH_VER}..."
    local email source_dir filename
    email="$(_resolve_acme_email "${1:-}")"
    # Prompt only when interactive; email is optional so never block without it.
    if [[ -z "$email" ]] && is_interactive; then
        read -r -p "Email for Let's Encrypt registration (optional, press Enter to skip): " email
    fi

    download_src "acme.sh" "$ACME_SH_URL" "$ACME_SH_SHA256"
    filename="$(basename "$ACME_SH_URL")"
    source_dir="${cur_dir}/src/acme.sh-${ACME_SH_VER}"
    rm -rf "$source_dir"
    tar -xzf "${cur_dir}/src/${filename}" -C "${cur_dir}/src" \
        || die_code "$EX_UNAVAILABLE" "Failed to extract pinned acme.sh ${ACME_SH_VER}"

    local -a install_args=(--install --home "$ACME_HOME" --nocron)
    [[ -n "$email" ]] && install_args+=(--accountemail "$email")
    ( cd "$source_dir" && ./acme.sh "${install_args[@]}" ) \
        || die_code "$EX_UNAVAILABLE" "Failed to install pinned acme.sh ${ACME_SH_VER}"
    [[ -s "$ACME_BIN" ]] \
        || die_code "$EX_UNAVAILABLE" "acme.sh installation did not create ${ACME_BIN}"

    # Use Let's Encrypt as default CA. Updates are performed explicitly through
    # `lnmp upgrade apply acme`, never by an unpinned upstream auto-update.
    "$ACME_BIN" --home "$ACME_HOME" --set-default-ca --server letsencrypt \
        || die_code "$EX_UNAVAILABLE" "Failed to configure acme.sh default CA."

    # Ensure cron job for auto-renewal.
    if ! crontab -l 2>/dev/null | grep -q 'acme.sh'; then
        { crontab -l 2>/dev/null || true; echo "0 3 * * * \"$ACME_BIN\" --cron --home \"$ACME_HOME\" --reloadcmd \"systemctl reload nginx\" > /dev/null 2>&1"; } | crontab -
        echo "Auto-renewal cron job installed (daily 3:00 AM)."
    fi

    record_installed_version ACME_SH "$ACME_SH_VER"
    rm -rf "$source_dir"
    echo "acme.sh ${ACME_SH_VER} installed to ${ACME_HOME}"
    _secure_acme_state
}

ssl_install() {
    local domain="" more_domains="" webroot="" keytype="ec-256"
    local challenge="http" dns_provider="" dns_credentials="" dns_sleep="" update_vhost="y"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keytype)        _require_option_arg "$1" "${2:-}"; keytype="$2"; shift 2 ;;
            --webroot)        _require_option_arg "$1" "${2:-}"; webroot="$2"; shift 2 ;;
            --domains)        _require_option_arg "$1" "${2:-}"; more_domains="$2"; shift 2 ;;
            --challenge)      _require_option_arg "$1" "${2:-}"; challenge="$2"; shift 2 ;;
            --dns-provider)   _require_option_arg "$1" "${2:-}"; dns_provider="$2"; shift 2 ;;
            --dns-credentials) _require_option_arg "$1" "${2:-}"; dns_credentials="$2"; shift 2 ;;
            --dns-sleep)      _require_option_arg "$1" "${2:-}"; dns_sleep="$2"; shift 2 ;;
            --no-vhost-update) update_vhost="n"; shift ;;
            --help|-h)        show_install_usage; exit 0 ;;
            -*)               show_install_usage; die_code "$EX_USAGE" "Unknown option: $1" ;;
            *)                [[ -z "$domain" ]] && domain="$1" || more_domains="${more_domains:+$more_domains }$1"; shift ;;
        esac
    done

    [[ -n "$domain" ]] || { is_interactive && read -r -p "Domain (e.g. example.com): " domain; }
    [[ -n "$domain" ]] \
        || die_code "$EX_USAGE" "Domain required. Usage: ssl.sh install <domain> [options]"
    if [[ -z "$more_domains" ]] && is_interactive; then
        read -r -p "More domains (space-separated, or empty): " more_domains
    fi

    validate_domain "$domain"
    [[ "$keytype" =~ ^(ec-256|ec-384|2048|3072|4096)$ ]] \
        || die_code "$EX_USAGE" "Invalid key type '${keytype}'. Use ec-256, ec-384, 2048, 3072, or 4096."
    [[ "$challenge" = http || "$challenge" = dns ]] \
        || die_code "$EX_USAGE" "Invalid challenge '${challenge}'. Use http or dns."
    if [[ "$challenge" = http ]]; then
        [[ -z "$dns_provider$dns_credentials$dns_sleep" ]] \
            || die_code "$EX_USAGE" "DNS options require --challenge dns."
    else
        [[ -n "$dns_provider" ]] \
            || die_code "$EX_USAGE" "DNS-01 requires --dns-provider."
        validate_dns_provider "$dns_provider"
        [[ -z "$webroot" ]] \
            || die_code "$EX_USAGE" "--webroot cannot be combined with --challenge dns."
        if [[ -n "$dns_sleep" ]]; then
            if [[ ! "$dns_sleep" =~ ^[0-9]+$ ]] \
                || (( dns_sleep < 1 || dns_sleep > 3600 )); then
                die_code "$EX_USAGE" "--dns-sleep must be an integer from 1 to 3600."
            fi
        fi
        if [[ -n "$dns_credentials" ]]; then
            _load_dns_credentials "$dns_provider" "$dns_credentials" n
        else
            _require_dns_credentials "$dns_provider"
        fi
    fi

    local -a more_domain_list=()
    local d normalized seen=",${domain,,},"
    if [[ -n "$more_domains" ]]; then
        read -r -a more_domain_list <<< "$more_domains"
        for d in "${more_domain_list[@]}"; do
            if [[ "$challenge" = http && "$d" == \*.* ]]; then
                die_code "$EX_USAGE" "Wildcard domain '${d}' requires --challenge dns."
            fi
            if [[ "$challenge" = dns ]]; then
                validate_certificate_domain "$d"
            else
                validate_domain "$d"
            fi
            normalized="${d,,}"
            [[ "$seen" != *",${normalized},"* ]] \
                || die_code "$EX_USAGE" "Duplicate certificate domain: ${d}"
            seen+="${normalized},"
        done
    fi

    local vhost_conf="${VHOST_DIR}/${domain}.conf"
    if [[ "$challenge" = http && ! -f "$vhost_conf" ]]; then
        die_code "$EX_USAGE" "HTTP-01 requires an existing vhost: ${vhost_conf}. Create it before installing SSL."
    fi
    if [[ -z "$webroot" && -f "$vhost_conf" ]]; then
        webroot=$(grep -m1 'root ' "$vhost_conf" | awk '{print $2}' | tr -d ';')
    fi
    [[ -z "$webroot" ]] && webroot="/home/wwwroot/${domain}"
    validate_abs_path "webroot" "$webroot"

    _ensure_acme
    if [[ "$challenge" = dns && ! -r "${ACME_HOME}/dnsapi/${dns_provider}.sh" ]]; then
        _clear_dns_credentials "$dns_provider"
        die_code "$EX_UNAVAILABLE" \
            "Pinned acme.sh ${ACME_SH_VER} does not provide the ${dns_provider} hook."
    fi
    if [[ "$challenge" = dns && -n "$dns_credentials" ]]; then
        _load_dns_credentials "$dns_provider" "$dns_credentials" y
        _require_dns_credentials "$dns_provider"
    fi

    local -a domain_args=(-d "$domain")
    for d in "${more_domain_list[@]}"; do
        domain_args+=(-d "$d")
    done
    local -a challenge_args=(-w "$webroot")
    if [[ "$challenge" = dns ]]; then
        challenge_args=(--dns "$dns_provider")
        [[ -n "$dns_sleep" ]] && challenge_args+=(--dnssleep "$dns_sleep")
    fi

    echo "Issuing certificate for ${domain} with ${challenge^^}-01..."
    local issue_rc=0
    "$ACME_BIN" --home "$ACME_HOME" --issue "${domain_args[@]}" \
        "${challenge_args[@]}" --keylength "$keytype" --server letsencrypt \
        || issue_rc=$?
    _secure_acme_state
    [[ "$challenge" = dns ]] && _clear_dns_credentials "$dns_provider"
    if [[ $issue_rc -ne 0 && $issue_rc -ne 2 ]]; then
        if [[ "$challenge" = dns ]]; then
            die_code "$EX_TEMPFAIL" \
                "DNS-01 issuance failed (acme.sh exit ${issue_rc}). Verify $(_dns_provider_hint "$dns_provider"), TXT create/delete permission, authoritative propagation, and CAA. Safe to retry."
        fi
        die_code "$EX_TEMPFAIL" \
            "HTTP-01 issuance failed (acme.sh exit ${issue_rc}). Verify DNS for ${domain}, port 80 reachability, the vhost challenge path, and firewall. Safe to retry."
    fi

    local cert_dir="${SSL_DIR}/${domain}"
    mkdir -p "$cert_dir"
    local -a ecc_args=()
    [[ "$keytype" == ec-* ]] && ecc_args=(--ecc)
    "$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$domain" "${ecc_args[@]}" \
        --key-file "${cert_dir}/key.pem" \
        --fullchain-file "${cert_dir}/fullchain.pem" \
        --reloadcmd "systemctl reload nginx" \
        || die_code "$EX_UNAVAILABLE" "Certificate issued but installation into ${cert_dir} failed."
    _secure_acme_state

    echo ""
    echo "Certificate installed:"
    echo "  Key:       ${cert_dir}/key.pem"
    echo "  Fullchain: ${cert_dir}/fullchain.pem"

    if [[ -f "$vhost_conf" && "$update_vhost" = y ]]; then
        if is_interactive; then
            read -r -p "Update Nginx vhost config for SSL? [Y/n]: " update_vhost
        fi
        if [[ ! "${update_vhost}" =~ ^[Nn]$ ]]; then
            _apply_ssl_vhost "$domain" "$more_domains" "$webroot" "$cert_dir"
        fi
    elif [[ -f "$vhost_conf" ]]; then
        echo "Nginx vhost update skipped by --no-vhost-update."
    else
        echo "No vhost config found at ${vhost_conf}; DNS-01 certificate installed without Nginx changes."
    fi
}

ssl_renew() {
    _ensure_acme

    local domain="${1:-}" renew_rc=0
    if [[ -n "$domain" ]]; then
        validate_domain "$domain"
        echo "Renewing certificate for ${domain}..."
        "$ACME_BIN" --home "$ACME_HOME" --renew -d "$domain" --force \
            || renew_rc=$?
    else
        echo "Renewing all certificates..."
        "$ACME_BIN" --home "$ACME_HOME" --renew-all || renew_rc=$?
    fi
    _secure_acme_state
    [[ "$renew_rc" -eq 0 ]] \
        || die_code "$EX_TEMPFAIL" "Certificate renewal failed (acme.sh exit ${renew_rc}). Existing installed certificates were left in place."
    "$SYSTEMCTL_BIN" reload nginx
    echo "Done."
}

ssl_revoke() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || { is_interactive && read -r -p "Domain to revoke: " domain; }
    [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain required. Usage: ssl.sh revoke <domain>"
    validate_domain "$domain"


    _ensure_acme

    "$ACME_BIN" --home "$ACME_HOME" --revoke -d "$domain"
    "$ACME_BIN" --home "$ACME_HOME" --remove -d "$domain"

    local cert_dir="${SSL_DIR}/${domain}"
    [[ -d "$cert_dir" ]] && rm -rf "$cert_dir"

    echo "Certificate for ${domain} revoked and removed."
    echo "Remember to update the Nginx vhost config."
}

ssl_list() {
    _ensure_acme
    echo "=== Installed Certificates ==="
    "$ACME_BIN" --home "$ACME_HOME" --list 2>/dev/null

    echo ""
    echo "=== Expiry Check ==="
    for cert_dir in "${SSL_DIR}"/*/; do
        [[ -f "${cert_dir}fullchain.pem" ]] || continue
        local domain expiry expiry_epoch now_epoch
        domain=$(basename "$cert_dir")
        expiry=$(openssl x509 -enddate -noout -in "${cert_dir}fullchain.pem" 2>/dev/null | cut -d= -f2)
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null) || {
            log_warn "Unable to parse certificate expiry for ${domain}"
            continue
        }
        now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        local status="✅"
        [[ $days_left -le 7 ]] && status="🔴"
        [[ $days_left -le 30 && $days_left -gt 7 ]] && status="⚠️"

        printf "  %s %-30s expires: %s (%d days)\n" "$status" "$domain" "$expiry" "$days_left"
    done
}

ssl_self() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || { is_interactive && read -r -p "Domain for self-signed cert: " domain; }
    [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain required. Usage: ssl.sh self <domain>"
    validate_domain "$domain"


    local cert_dir="${SSL_DIR}/${domain}"
    mkdir -p "$cert_dir"

    openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${cert_dir}/key.pem" \
        -out "${cert_dir}/fullchain.pem" \
        -subj "/CN=${domain}" 2>/dev/null

    echo "Self-signed certificate created:"
    echo "  Key:       ${cert_dir}/key.pem"
    echo "  Fullchain: ${cert_dir}/fullchain.pem"

    local vhost_conf="${VHOST_DIR}/${domain}.conf"
    if [[ -f "$vhost_conf" ]]; then
        local webroot="/home/wwwroot/${domain}"
        local configured_root
        configured_root=$(grep -m1 'root ' "$vhost_conf" | awk '{print $2}' | tr -d ';')
        [[ -n "$configured_root" ]] && webroot="$configured_root"

        local update_vhost="y"
        if is_interactive; then
            read -r -p "Update Nginx vhost config for SSL? [Y/n]: " update_vhost
        fi
        if [[ ! "${update_vhost}" =~ ^[Nn]$ ]]; then
            _apply_ssl_vhost "$domain" "" "$webroot" "$cert_dir"
        fi
    else
        echo "No vhost config found at ${vhost_conf}; certificate created without Nginx changes."
    fi
}

_apply_ssl_vhost() {
    local domain="$1" more_domains="$2" webroot="$3" cert_dir="$4"
    local -a more_domain_list=()
    local server_names="$domain"
    if [[ -n "$more_domains" ]]; then
        read -r -a more_domain_list <<< "$more_domains"
        server_names="${domain} ${more_domain_list[*]}"
    fi

    local vhost_conf="${VHOST_DIR}/${domain}.conf"
    [[ -f "$vhost_conf" ]] || die_code "$EX_USAGE" "Vhost config not found: ${vhost_conf}. Create the vhost before installing SSL."
    validate_domain "$domain"
    ((${#more_domain_list[@]} == 0)) || validate_certificate_domain_list "${more_domain_list[@]}"
    validate_abs_path "webroot" "$webroot"
    validate_abs_path "certificate directory" "$cert_dir"


    # Remove existing SSL block if any
    if grep -q 'listen 443' "$vhost_conf" 2>/dev/null; then
        echo "SSL block already exists in ${vhost_conf}, skipping."
        return 0
    fi

    # Detect rewrite rule from existing config
    local rewrite="none"
    local rewrite_line
    rewrite_line=$(grep -m1 'include rewrite/' "$vhost_conf" 2>/dev/null | sed 's/.*include //' | tr -d ';')
    [[ -n "$rewrite_line" ]] && rewrite="$rewrite_line"

    # Optional: redirect HTTP to HTTPS
    if ! grep -q 'return 301 https' "$vhost_conf" 2>/dev/null; then
        local do_redirect="${FORCE_REDIRECT:-}"
        if [[ -z "$do_redirect" ]]; then
            if is_interactive; then
                read -r -p "Redirect HTTP to HTTPS (301)? [Y/n]: " do_redirect
                [[ -z "$do_redirect" ]] && do_redirect="y"
            else
                do_redirect="y"
            fi
        fi
        if [[ "${do_redirect}" =~ ^[Yy]$ ]]; then
            # Insert redirect after the first 'index' line in the first server block only
            # shellcheck disable=SC2016 # keep nginx $host/$request_uri literals
            sed -i '0,/^\s*index /{/^\s*index /a\
\
    return 301 https://$host$request_uri;
}' "$vhost_conf" 2>/dev/null
        fi
    fi

    # Append SSL server block
    cat >> "$vhost_conf" <<EOF

server {
    listen 443 ssl;
    # listen [::]:443 ssl;
    http2 on;
    server_name ${server_names};
    root ${webroot};
    index index.html index.htm index.php;

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    ssl_dhparam /usr/local/nginx/conf/ssl/dhparam.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    access_log /home/wwwlogs/${domain}.log main;
    error_log /home/wwwlogs/${domain}.error.log;

    include ${rewrite};

    location ~ \.php\$ {
        fastcgi_pass unix:/tmp/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;
        fastcgi_param PHP_ADMIN_VALUE "open_basedir=${webroot}:/tmp/:/proc/";
    }

    location ~ /\. {
        deny all;
    }
}
EOF

    "$NGINX_BIN" -t && "$SYSTEMCTL_BIN" reload nginx
    echo "Nginx vhost updated with SSL."
}

show_usage() {
    cat <<'EOF'
Usage:
  lnmp ssl {install|renew|revoke|list|self|client-upgrade}
  ssl.sh {install|renew|revoke|list|self|client-upgrade}

Commands:
  install <domain> [options]  Issue/install a Let's Encrypt certificate with
                              HTTP-01 (default) or DNS-01.
                              See: lnmp ssl install --help
  renew [domain]              Renew one certificate, or all if omitted.
  revoke <domain>             Revoke and remove certificate files.
  list                        List certificates and expiry status.
  self <domain>               Create self-signed cert; updates vhost only when
                              the vhost config already exists.
  client-upgrade              Install the repository-pinned acme.sh release.

Agent / CI rules:
  - Use lnmp --yes ssl ... for deterministic non-interactive execution.
  - HTTP-01 remains the default and requires an existing vhost, correct A/AAAA,
    shared webroot, and reachable port 80.
  - DNS-01 is explicit, supports wildcard SANs, and requires a supported DNS
    API provider plus least-privilege credentials or an AWS IAM role.
  - Exit 64 = bad input; 69 = client/credentials unavailable; 75 = temporary
    issuance, provider API, CAA, propagation, or renewal failure.
EOF
}

has_help_arg() {
    local arg
    for arg in "$@"; do
        case "$arg" in --help|-h|help) return 0 ;; esac
    done
    return 1
}

reject_extra_args() {
    local usage="$1"
    shift
    [[ $# -eq 0 ]] && return 0
    show_usage
    die_code "$EX_USAGE" "Unexpected argument: $1. Usage: ${usage}"
}


# --- Main ---
case "${1:-}" in
    install)  shift; ssl_install "$@" ;;
    renew)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl renew [domain]"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        ssl_renew "${1:-}"
        ;;
    revoke)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl revoke <domain>"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        ssl_revoke "${1:-}"
        ;;
    list|ls)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl list"; exit 0; fi
        reject_extra_args "lnmp ssl list" "$@"
        ssl_list
        ;;
    self)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp ssl self <domain>"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        ssl_self "${1:-}"
        ;;
    client-upgrade)
        shift
        reject_extra_args "lnmp ssl client-upgrade" "$@"
        check_root
        _ensure_acme "" y
        ;;
    --help|-h|help) show_usage; exit 0 ;;
    "")
        show_usage
        exit 64
        ;;
    *)
        show_usage
        exit 64
        ;;
esac
