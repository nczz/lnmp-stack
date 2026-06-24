#!/usr/bin/env bash
# lib/php.sh — PHP compile and install

install_php() {
    log_info "=== Installing PHP ${PHP_VER} ==="

    download_src "PHP" "$PHP_URL"
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
    [[ "${Enable_PHP_Fileinfo}" = 'y' ]] && php_configure_args+=( --enable-fileinfo ) || php_configure_args+=( --disable-fileinfo )
    [[ "${Enable_PHP_Exif}" = 'y' ]] && php_configure_args+=( --enable-exif )
    [[ "${Enable_PHP_Ldap}" = 'y' ]] && php_configure_args+=( --with-ldap --with-ldap-sasl )
    [[ "${Enable_PHP_Bz2}" = 'y' ]] && php_configure_args+=( --with-bz2 )
    [[ "${Enable_PHP_Sodium}" = 'y' ]] && php_configure_args+=( --with-sodium )
    [[ "${Enable_PHP_Imap}" = 'y' ]] && php_configure_args+=( --with-imap --with-imap-ssl --with-kerberos )

    # User-defined extra options
    [[ -n "${PHP_Modules_Options}" ]] && php_configure_args+=( ${PHP_Modules_Options} )

    # Prioritize system pkg-config paths to avoid /usr/local contamination
    export PKG_CONFIG_PATH="/usr/lib/${ARCH}-linux-gnu/pkgconfig:/usr/share/pkgconfig"

    ./configure "${php_configure_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "PHP configure failed"

    make_install

    # Setup config directories
    mkdir -p /usr/local/php/etc/php.d

    _deploy_php_conf
    _deploy_phpfpm_conf

    # Ensure runtime directories
    mkdir -p /usr/local/php/var/run

    # Install systemd unit
    cp "${cur_dir}/systemd/php-fpm.service" /etc/systemd/system/php-fpm.service
    systemctl daemon-reload
    systemctl enable php-fpm

    # Symlinks
    ln -sf /usr/local/php/bin/php /usr/bin/php
    ln -sf /usr/local/php/bin/phpize /usr/bin/phpize
    ln -sf /usr/local/php/bin/php-config /usr/bin/php-config
    ln -sf /usr/local/php/bin/pecl /usr/bin/pecl
    ln -sf /usr/local/php/sbin/php-fpm /usr/bin/php-fpm

    # Install Composer
    [[ "${Enable_Composer}" = 'y' ]] && _install_composer

    # phpMyAdmin
    [[ "${Enable_phpMyAdmin}" = 'y' ]] && _install_phpmyadmin

    # phpinfo for verification
    echo "<?php phpinfo(); ?>" > "${Default_Website_Dir:-/home/wwwroot/default}/phpinfo.php"

    log_ok "PHP ${PHP_VER} installed."
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
    log_info "Installing Composer..."
    curl -sS --connect-timeout 30 -m 60 https://getcomposer.org/installer \
        | /usr/local/php/bin/php -- --install-dir=/usr/local/bin --filename=composer 2>&1 | tee -a "$LOG_FILE"
    if [[ -x /usr/local/bin/composer ]]; then
        log_ok "Composer installed."
    else
        log_warn "Composer installation failed. Install manually later."
    fi
}

_install_phpmyadmin() {
    local dest="${Default_Website_Dir:-/home/wwwroot/default}/phpmyadmin"

    if [[ -d "$dest" ]]; then
        log_info "phpMyAdmin already exists at ${dest}, skipping."
        return 0
    fi

    log_info "Installing phpMyAdmin ${PHPMYADMIN_VER}..."
    download_src "phpMyAdmin" "$PHPMYADMIN_URL"

    local filename="$(basename "$PHPMYADMIN_URL")"
    cd "${cur_dir}/src"
    tar Jxf "$filename"
    mv "phpMyAdmin-${PHPMYADMIN_VER}-all-languages" "$dest"

    # Generate blowfish secret
    local secret
    secret="$(openssl rand -hex 16)"
    cp "${dest}/config.sample.inc.php" "${dest}/config.inc.php"
    sed -i "s|\$cfg\['blowfish_secret'\] = ''|\$cfg['blowfish_secret'] = '${secret}'|" "${dest}/config.inc.php"

    chown -R www:www "$dest"
    log_ok "phpMyAdmin installed at http://<IP>/phpmyadmin/"
}
