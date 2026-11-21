#!/usr/bin/env bash
# lib/php.sh — PHP compile and install

_queue_legacy_imap_extension() {
    # IMAP was unbundled from PHP core in PHP 8.4 and must be installed as a
    # PECL extension. Keep the legacy flag as a compatibility alias so existing
    # lnmp.conf.local files still produce the requested capability.
    [[ "${Enable_PHP_Imap:-n}" = 'y' ]] || return 0
    [[ "${_LEGACY_IMAP_QUEUE_NORMALIZED:-n}" = 'y' ]] && return 0
    _LEGACY_IMAP_QUEUE_NORMALIZED='y'

    log_warn "Enable_PHP_Imap='y' queues the PECL IMAP extension; PHP ${PHP_VER} no longer builds IMAP into core."
    case " ${PHP_Extensions_Install:-} " in
        *" imap "*) ;;
        *)
            PHP_Extensions_Install="${PHP_Extensions_Install:-} imap"
            PHP_Extensions_Install="${PHP_Extensions_Install# }"
            log_warn "Added 'imap' to PHP_Extensions_Install for this run."
            ;;
    esac
}

_php_fpm_master_pid() {
    pgrep -o php-fpm 2>/dev/null
}

_php_fpm_wait_for_exit() {
    local pid="$1" i
    for ((i = 0; i < 120; i++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    return 1
}

_start_php_fpm_candidate() {
    local live_prefix="$1" config="$2" service="$3" i pid actual
    systemctl reset-failed "$service" 2>/dev/null || true
    systemctl start "$service" 2>/dev/null || true
    for ((i = 0; i < 10; i++)); do
        pid=$(_php_fpm_master_pid || true)
        actual=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
        [[ "$actual" = "${live_prefix}/sbin/php-fpm" ]] && return 0
        sleep 1
    done
    systemctl stop "$service" 2>/dev/null || true
    "${live_prefix}/sbin/php-fpm" -y "$config" >/dev/null 2>&1 || return 1
    for ((i = 0; i < 10; i++)); do
        pid=$(_php_fpm_master_pid || true)
        actual=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
        [[ "$actual" = "${live_prefix}/sbin/php-fpm" ]] && return 0
        sleep 1
    done
    return 1
}

_deploy_php_candidate() {
    local candidate="$1" live_prefix="$2" service="${3:-php-fpm}"
    local config="${4:-${PHP_INI_ROOT:-/usr/local/php/etc}/php-fpm.conf}"
    local previous old_pid
    [[ -d "$candidate" && -d "$live_prefix" && -f "$config" ]] || return 1
    old_pid=$(_php_fpm_master_pid) || return 1
    previous=$(mktemp -d "${live_prefix}.previous.$(date +%Y%m%d%H%M%S)-XXXXXX") \
        || return 1
    rmdir "$previous" || return 1

    systemctl stop "$service" 2>/dev/null || true
    if kill -0 "$old_pid" 2>/dev/null; then
        kill -QUIT "$old_pid" || return 1
        _php_fpm_wait_for_exit "$old_pid" || return 1
    fi
    if ! mv "$live_prefix" "$previous"; then
        _start_php_fpm_candidate "$live_prefix" "$config" "$service" 2>/dev/null || true
        return 1
    fi
    if ! mv "$candidate" "$live_prefix"; then
        mv "$previous" "$live_prefix" 2>/dev/null || true
        _start_php_fpm_candidate "$live_prefix" "$config" "$service" 2>/dev/null || true
        return 1
    fi
    if ! _start_php_fpm_candidate "$live_prefix" "$config" "$service"; then
        rm -rf "$live_prefix"
        mv "$previous" "$live_prefix" 2>/dev/null || true
        _start_php_fpm_candidate "$live_prefix" "$config" "$service" 2>/dev/null || true
        return 1
    fi
    PHP_DEPLOY_PREVIOUS="$previous"
    if [[ -n "${PHP_DEPLOY_STATE_FILE:-}" ]]; then
        printf '%s\n' "$previous" > "$PHP_DEPLOY_STATE_FILE" || return 1
        chmod 0600 "$PHP_DEPLOY_STATE_FILE" || return 1
    fi
}

install_php() {
    local mode="${1:-install}"
    [[ "$mode" = 'install' || "$mode" = 'upgrade' ]] || die "Invalid PHP install mode: ${mode}"
    log_info "=== ${mode^}ing PHP ${PHP_VER} ==="

    download_src "PHP" "$PHP_URL" "$PHP_SHA256"
    tar_cd "php-${PHP_VER}.tar.xz" "php-${PHP_VER}"

    local config_path="${PHP_INI_ROOT:-/usr/local/php/etc}"
    local scan_path="${PHP_INI_SCAN_DIR:-/usr/local/php/etc/php.d}"
    local arg
    local -a php_configure_args=()
    if [[ "$mode" = upgrade && -n "${PHP_UPGRADE_CONFIGURE_OPTIONS:-}" ]]; then
        local -a previous_configure_args=()
        read -r -a previous_configure_args <<< "$PHP_UPGRADE_CONFIGURE_OPTIONS"
        php_configure_args=(
            --prefix=/usr/local/php
            "--with-config-file-path=${config_path}"
            "--with-config-file-scan-dir=${scan_path}"
        )
        for arg in "${previous_configure_args[@]}"; do
            case "$arg" in
                --prefix=*|--with-config-file-path=*|--with-config-file-scan-dir=*|PKG_CONFIG_PATH=*) ;;
                *) php_configure_args+=("$arg") ;;
            esac
        done
    else
        php_configure_args=(
            --prefix=/usr/local/php
            "--with-config-file-path=${config_path}"
            "--with-config-file-scan-dir=${scan_path}"
            --enable-fpm
            --with-fpm-user=www
            --with-fpm-group=www
            --with-fpm-systemd
            --enable-mysqlnd
            --with-mysqli=mysqlnd
            --with-pdo-mysql=mysqlnd
            --with-iconv
            --with-freetype
            --with-jpeg
            --with-webp
            --with-avif
            --with-zlib
            --with-curl
            --with-openssl
            --with-mhash
            --with-xsl
            --with-gettext
            --with-zip
            --with-gmp
            --with-readline
            --enable-xml
            --enable-bcmath
            --enable-shmop
            --enable-sysvsem
            --enable-mbregex
            --enable-mbstring
            --enable-pcntl
            --enable-sockets
            --enable-soap
            --enable-calendar
            --enable-intl
            --enable-opcache
            --enable-gd
            --disable-debug
            --disable-rpath
        )

        [[ "${Enable_PHP_Fileinfo:-n}" = y ]] && php_configure_args+=( --enable-fileinfo ) || php_configure_args+=( --disable-fileinfo )
        [[ "${Enable_PHP_Exif:-n}" = y ]] && php_configure_args+=( --enable-exif )
        [[ "${Enable_PHP_Ldap:-n}" = y ]] && php_configure_args+=( --with-ldap --with-ldap-sasl )
        [[ "${Enable_PHP_Bz2:-n}" = y ]] && php_configure_args+=( --with-bz2 )
        [[ "${Enable_PHP_Sodium:-n}" = y ]] && php_configure_args+=( --with-sodium )
        _queue_legacy_imap_extension

        if [[ -n "${PHP_Modules_Options}" ]]; then
            local -a php_extra_args=()
            read -r -a php_extra_args <<< "${PHP_Modules_Options}"
            php_configure_args+=( "${php_extra_args[@]}" )
        fi
    fi

    # Prioritize system pkg-config paths to avoid /usr/local contamination
    export PKG_CONFIG_PATH="/usr/lib/${ARCH:?detect_os must run before install_php}-linux-gnu/pkgconfig:/usr/share/pkgconfig"

    ./configure "${php_configure_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "PHP configure failed"

    make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "PHP build failed"
    if [[ "$mode" = 'upgrade' ]]; then
        local stage candidate candidate_version
        stage=$(mktemp -d /usr/local/.lnmp-php-stage.XXXXXX) \
            || die "Cannot create PHP candidate staging directory."
        candidate="${stage}/usr/local/php"
        mkdir -p "$candidate" \
            || { rm -rf "$stage"; die "Cannot prepare PHP candidate prefix."; }
        cp -a /usr/local/php/. "$candidate/" \
            || { rm -rf "$stage"; die "Cannot seed PHP candidate with active configuration."; }
        if ! make install INSTALL_ROOT="$stage" 2>&1 | tee -a "$LOG_FILE"; then
            rm -rf "$stage"
            die "PHP candidate installation failed; active prefix was not changed."
        fi
        candidate_version=$("${candidate}/bin/php" -n -r 'echo PHP_VERSION;' 2>/dev/null || true)
        [[ "$candidate_version" = "$PHP_VER" ]] \
            || { rm -rf "$stage"; die "PHP candidate version mismatch: ${candidate_version:-unknown}."; }
        "${candidate}/bin/php" -m >/dev/null 2>&1 \
            || { rm -rf "$stage"; die "PHP candidate cannot load the active module configuration."; }
        "${candidate}/sbin/php-fpm" -t -y "${config_path}/php-fpm.conf" >/dev/null 2>&1 \
            || { rm -rf "$stage"; die "PHP candidate failed PHP-FPM configuration validation."; }
        if ! _deploy_php_candidate "$candidate" /usr/local/php php-fpm "${config_path}/php-fpm.conf"; then
            rm -rf "$stage"
            die "PHP candidate deployment failed; the previous service was restarted when possible."
        fi
        rm -rf "$stage"
    else
        make install 2>&1 | tee -a "$LOG_FILE"
        [[ ${PIPESTATUS[0]} -eq 0 ]] || die "PHP installation failed"
    fi

    if [[ "$mode" = 'install' ]]; then
        mkdir -p /usr/local/php/etc/php.d
        _deploy_php_conf
        _deploy_phpfpm_conf
        mkdir -p /usr/local/php/var/run

        cp "${cur_dir:?lib/common.sh must be sourced before lib/php.sh}/systemd/php-fpm.service" /etc/systemd/system/php-fpm.service
        systemctl daemon-reload
        systemctl enable php-fpm
    fi

    [[ "$mode" = install ]] && _enforce_php_security_baseline
    _remove_generated_phpinfo

    ln -sf /usr/local/php/bin/php /usr/bin/php
    ln -sf /usr/local/php/bin/phpize /usr/bin/phpize
    ln -sf /usr/local/php/bin/php-config /usr/bin/php-config
    ln -sf /usr/local/php/bin/pecl /usr/bin/pecl
    ln -sf /usr/local/php/sbin/php-fpm /usr/bin/php-fpm

    if [[ "$mode" = 'install' ]]; then
        [[ "${Enable_Composer:-n}" = 'y' ]] && _install_composer n
    fi

    record_installed_version PHP "$PHP_VER"
    log_ok "PHP ${PHP_VER} ${mode} completed."
}

_deploy_php_conf() {
    local tz="${Timezone:-UTC}"
    local config_dir="${PHP_CONFIG_DEST_DIR:-/usr/local/php/etc}"
    mkdir -p "${config_dir}/php.d"

    sed -e "s|{{TIMEZONE}}|${tz}|g" \
        -e "s|{{MEMORY_LIMIT}}|${PHP_MEMORY_LIMIT}|g" \
        "${cur_dir}/conf/php/php.ini" > "${config_dir}/php.ini"

    # OPcache config
    cat > "${config_dir}/php.d/opcache.ini" <<'EOF'
[opcache]
zend_extension=opcache.so
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.save_comments=1
; JIT is disabled by default because it can trigger runtime bugs on some
; workloads and PHP extension combinations. OPcache itself remains enabled.
; Uncomment both lines below only when the workload has been validated with JIT.
; opcache.jit_buffer_size=64M
; opcache.jit=1255
EOF
}

_enforce_php_security_baseline() {
    local security_ini='/usr/local/php/etc/php.d/99-lnmp-security.ini'
    mkdir -p /usr/local/php/etc/php.d
    cat > "$security_ini" <<'EOF'
; Defense in depth for session upload handling. PHP 8.4.28 contains the complete
; CVE-2026-115560 fix, but LNMP does not enable upload-progress state by default.
session.upload_progress.enabled=0
EOF
    if ! /usr/local/php/bin/php -r \
        'exit(ini_get("session.upload_progress.enabled") === "0" ? 0 : 1);'; then
        die "PHP security baseline verification failed: session upload progress is enabled."
    fi
}

_remove_generated_phpinfo() {
    local phpinfo="${Default_Website_Dir:-/home/wwwroot/default}/phpinfo.php"
    if [[ -f "$phpinfo" ]] \
        && [[ "$(wc -l < "$phpinfo")" -eq 1 ]] \
        && grep -Fqx '<?php phpinfo(); ?>' "$phpinfo"; then
        rm -f "$phpinfo" || die "Cannot remove installer-generated phpinfo.php."
        log_ok "Removed installer-generated public phpinfo.php."
    fi
}

_validate_php_fpm_disable_functions() {
    local value="$1" item normalized seen=','
    local php_bin="${PHP_CONFIG_PHP_BIN:-/usr/local/php/bin/php}"
    local -a functions=()
    [[ -z "$value" ]] && return 0
    [[ "$value" =~ ^[[:alpha:]_][[:alnum:]_]*(,[[:alpha:]_][[:alnum:]_]*)*$ ]] \
        || die "PHP_FPM_DISABLE_FUNCTIONS must be comma-separated function names without spaces."
    IFS=',' read -r -a functions <<< "$value"
    for item in "${functions[@]}"; do
        normalized="${item,,}"
        [[ "$seen" != *",${normalized},"* ]] \
            || die "PHP_FPM_DISABLE_FUNCTIONS contains a duplicate function: ${item}"
        seen+="${normalized},"
        if [[ -x "$php_bin" ]] \
            && ! "$php_bin" -r "exit(function_exists('${item}') ? 0 : 1);" >/dev/null 2>&1; then
            log_warn "PHP_FPM_DISABLE_FUNCTIONS names '${item}', which is not currently defined; verify spelling or install its extension."
        fi
    done
}

_deploy_phpfpm_conf() {
    local config_dir="${PHP_CONFIG_DEST_DIR:-/usr/local/php/etc}"
    local disabled="${PHP_FPM_DISABLE_FUNCTIONS-exec,passthru,shell_exec,system,popen,proc_open,pcntl_exec,pcntl_fork}"
    _validate_php_fpm_disable_functions "$disabled"
    mkdir -p "$config_dir"
    sed -e "s|{{MAX_CHILDREN}}|${PHP_FPM_MAX_CHILDREN}|g" \
        -e "s|{{START_SERVERS}}|${PHP_FPM_START_SERVERS}|g" \
        -e "s|{{MIN_SPARE}}|${PHP_FPM_MIN_SPARE}|g" \
        -e "s|{{MAX_SPARE}}|${PHP_FPM_MAX_SPARE}|g" \
        -e "s|{{DISABLE_FUNCTIONS}}|${disabled}|g" \
        "${cur_dir}/conf/php/php-fpm.conf" > "${config_dir}/php-fpm.conf"

    log_info "PHP-FPM config: max_children=${PHP_FPM_MAX_CHILDREN}, memory_limit=${PHP_MEMORY_LIMIT}, disabled_web_functions=${disabled:-none}"
}

_install_composer() {
    local force="${1:-n}"
    if [[ "$force" != 'y' && -x /usr/local/bin/composer ]]; then
        local current
        current=$(composer_version || true)
        if [[ "$current" = "$COMPOSER_VER" ]]; then
            log_info "Composer ${COMPOSER_VER} already installed, skipping."
            return 0
        fi
    fi

    log_info "Installing Composer ${COMPOSER_VER}..."
    download_src "Composer" "$COMPOSER_URL" "$COMPOSER_SHA256"
    install -m 0755 "${cur_dir}/src/$(basename "$COMPOSER_URL")" /usr/local/bin/composer
    local installed
    installed=$(composer_version || true)
    [[ "$installed" = "$COMPOSER_VER" ]] || die "Composer verification failed: expected ${COMPOSER_VER}, got ${installed:-unknown}"
    record_installed_version COMPOSER "$COMPOSER_VER"
    log_ok "Composer ${COMPOSER_VER} installed."
}
