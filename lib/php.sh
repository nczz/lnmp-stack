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

install_php() {
    local mode="${1:-install}"
    [[ "$mode" = 'install' || "$mode" = 'upgrade' ]] || die "Invalid PHP install mode: ${mode}"
    log_info "=== ${mode^}ing PHP ${PHP_VER} ==="

    download_src "PHP" "$PHP_URL" "$PHP_SHA256"
    tar_cd "php-${PHP_VER}.tar.xz" "php-${PHP_VER}"

    local php_configure_args=(
        --prefix=/usr/local/php
        --with-config-file-path=/usr/local/php/etc
        --with-config-file-scan-dir=/usr/local/php/etc/php.d
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

    # Optional extensions from lnmp.conf
    [[ "${Enable_PHP_Fileinfo:-n}" = 'y' ]] && php_configure_args+=( --enable-fileinfo ) || php_configure_args+=( --disable-fileinfo )
    [[ "${Enable_PHP_Exif:-n}" = 'y' ]] && php_configure_args+=( --enable-exif )
    [[ "${Enable_PHP_Ldap:-n}" = 'y' ]] && php_configure_args+=( --with-ldap --with-ldap-sasl )
    [[ "${Enable_PHP_Bz2:-n}" = 'y' ]] && php_configure_args+=( --with-bz2 )
    [[ "${Enable_PHP_Sodium:-n}" = 'y' ]] && php_configure_args+=( --with-sodium )
    _queue_legacy_imap_extension

    # User-defined extra options
    if [[ -n "${PHP_Modules_Options}" ]]; then
        local -a php_extra_args=()
        read -r -a php_extra_args <<< "${PHP_Modules_Options}"
        php_configure_args+=( "${php_extra_args[@]}" )
    fi

    # Prioritize system pkg-config paths to avoid /usr/local contamination
    export PKG_CONFIG_PATH="/usr/lib/${ARCH:?detect_os must run before install_php}-linux-gnu/pkgconfig:/usr/share/pkgconfig"

    ./configure "${php_configure_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "PHP configure failed"

    make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "PHP build failed"
    if [[ "$mode" = 'upgrade' ]]; then
        systemctl stop php-fpm || die "Cannot stop PHP-FPM for deployment."
    fi
    make install 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "PHP installation failed"

    if [[ "$mode" = 'install' ]]; then
        mkdir -p /usr/local/php/etc/php.d
        _deploy_php_conf
        _deploy_phpfpm_conf
        mkdir -p /usr/local/php/var/run

        cp "${cur_dir:?lib/common.sh must be sourced before lib/php.sh}/systemd/php-fpm.service" /etc/systemd/system/php-fpm.service
        systemctl daemon-reload
        systemctl enable php-fpm
    fi

    _enforce_php_security_baseline
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

    sed -e "s|{{TIMEZONE}}|${tz}|g" \
        -e "s|{{MEMORY_LIMIT}}|${PHP_MEMORY_LIMIT}|g" \
        "${cur_dir}/conf/php/php.ini" > /usr/local/php/etc/php.ini

    # OPcache config
    cat > /usr/local/php/etc/php.d/opcache.ini <<'EOF'
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
; PHP's 2026-10-23 advisory recommends disabling this feature until a release
; containing the complete CVE-2026-115560 fix is available.
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

_deploy_phpfpm_conf() {
    sed -e "s|{{MAX_CHILDREN}}|${PHP_FPM_MAX_CHILDREN}|g" \
        -e "s|{{START_SERVERS}}|${PHP_FPM_START_SERVERS}|g" \
        -e "s|{{MIN_SPARE}}|${PHP_FPM_MIN_SPARE}|g" \
        -e "s|{{MAX_SPARE}}|${PHP_FPM_MAX_SPARE}|g" \
        "${cur_dir}/conf/php/php-fpm.conf" > /usr/local/php/etc/php-fpm.conf

    cp "${cur_dir}/conf/php/www.conf" /usr/local/php/etc/php-fpm.d/www.conf 2>/dev/null || true

    log_info "PHP-FPM config: max_children=${PHP_FPM_MAX_CHILDREN}, memory_limit=${PHP_MEMORY_LIMIT}"
}

_install_composer() {
    local force="${1:-n}"
    if [[ "$force" != 'y' && -x /usr/local/bin/composer ]]; then
        local current
        current=$(/usr/local/php/bin/php /usr/local/bin/composer --version --no-ansi 2>/dev/null | awk '{print $3}')
        if [[ "$current" = "$COMPOSER_VER" ]]; then
            log_info "Composer ${COMPOSER_VER} already installed, skipping."
            return 0
        fi
    fi

    log_info "Installing Composer ${COMPOSER_VER}..."
    download_src "Composer" "$COMPOSER_URL" "$COMPOSER_SHA256"
    install -m 0755 "${cur_dir}/src/$(basename "$COMPOSER_URL")" /usr/local/bin/composer
    local installed
    installed=$(/usr/local/php/bin/php /usr/local/bin/composer --version --no-ansi 2>/dev/null | awk '{print $3}')
    [[ "$installed" = "$COMPOSER_VER" ]] || die "Composer verification failed: expected ${COMPOSER_VER}, got ${installed:-unknown}"
    record_installed_version COMPOSER "$COMPOSER_VER"
    log_ok "Composer ${COMPOSER_VER} installed."
}
