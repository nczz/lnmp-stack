#!/usr/bin/env bash
# lib/extensions.sh — PHP extension compilation framework
#
# Usage (from addons.sh):
#   install_extension redis
#   install_extension imagick
#   uninstall_extension redis

PHP_BIN=/usr/local/php/bin/php
PHPIZE=/usr/local/php/bin/phpize
PHP_CONFIG=/usr/local/php/bin/php-config
PHP_EXT_DIR=""
PHP_INI_SCAN_DIR=/usr/local/php/etc/php.d

_init_php_ext_dir() {
    [[ -n "$PHP_EXT_DIR" ]] && return 0
    PHP_EXT_DIR=$($PHP_CONFIG --extension-dir 2>/dev/null || echo "")
}

# Extension registry: name -> url_var, configure_opts, system_deps
declare -A EXT_URL_VAR EXT_CONFIGURE EXT_DEPS || true

EXT_URL_VAR[redis]='REDIS_EXT_URL'
EXT_CONFIGURE[redis]=''
EXT_DEPS[redis]=''

EXT_URL_VAR[imagick]='IMAGICK_URL'
EXT_CONFIGURE[imagick]=''
EXT_DEPS[imagick]='libmagickwand-dev'

EXT_URL_VAR[apcu]='APCU_URL'
EXT_CONFIGURE[apcu]=''
EXT_DEPS[apcu]=''

EXT_URL_VAR[swoole]='SWOOLE_URL'
EXT_CONFIGURE[swoole]='--enable-openssl --enable-sockets --enable-mysqlnd --enable-http2'
EXT_DEPS[swoole]='libssl-dev libcurl4-openssl-dev'

EXT_URL_VAR[memcached]='MEMCACHED_EXT_URL'
EXT_CONFIGURE[memcached]='--with-libmemcached-dir=/usr --disable-memcached-sasl'
EXT_DEPS[memcached]='libmemcached-dev'

EXT_URL_VAR[sodium]='SODIUM_EXT_URL'
EXT_CONFIGURE[sodium]=''
EXT_DEPS[sodium]='libsodium-dev'

# List available extensions
list_extensions() {
    echo "Available extensions:"
    for ext in "${!EXT_URL_VAR[@]}"; do
        local status="not installed"
        if $PHP_BIN -m 2>/dev/null | grep -qi "^${ext}$"; then
            status="installed"
        fi
        printf "  %-15s [%s]\n" "$ext" "$status"
    done
}

# Install a PHP extension by name
# Usage: install_extension <name>
install_extension() {
    local ext="$1"
    _init_php_ext_dir

    [[ -n "${EXT_URL_VAR[$ext]+x}" ]] || die "Unknown extension: ${ext}. Run with 'list' to see available."

    if $PHP_BIN -m 2>/dev/null | grep -qi "^${ext}$"; then
        log_warn "Extension '${ext}' is already loaded. Skipping."
        return 0
    fi

    log_info "=== Installing PHP extension: ${ext} ==="

    # Install system dependencies
    local deps="${EXT_DEPS[$ext]}"
    if [[ -n "$deps" ]]; then
        log_info "Installing dependencies: ${deps}"
        apt-get -y install $deps 2>&1 | tee -a "$LOG_FILE"
    fi

    # Download
    local url_var="${EXT_URL_VAR[$ext]}"
    local url="${!url_var}"
    [[ -n "$url" ]] || die "No URL defined for extension: ${ext}"

    local filename="$(basename "$url")"
    download_src "${ext}" "$url"

    # Extract
    cd "${cur_dir}/src"
    local dirname="${filename%.tgz}"
    dirname="${dirname%.tar.gz}"
    [[ -d "$dirname" ]] && rm -rf "$dirname"
    tar zxf "$filename"
    cd "$dirname" || die "Cannot cd to ${dirname}"

    # Build
    $PHPIZE
    ./configure --with-php-config=$PHP_CONFIG ${EXT_CONFIGURE[$ext]} 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Configure failed for ${ext}"

    make_install

    # Enable
    local ini_file="${PHP_INI_SCAN_DIR}/${ext}.ini"
    echo "extension=${ext}.so" > "$ini_file"

    # Verify
    if $PHP_BIN -m 2>/dev/null | grep -qi "^${ext}$"; then
        log_ok "Extension '${ext}' installed and loaded."
    else
        log_err "Extension '${ext}' installed but failed to load. Check: php -m"
    fi
}

# Uninstall a PHP extension
uninstall_extension() {
    local ext="$1"
    _init_php_ext_dir
    local ini_file="${PHP_INI_SCAN_DIR}/${ext}.ini"
    local so_file="${PHP_EXT_DIR}/${ext}.so"

    [[ -f "$ini_file" ]] && rm -f "$ini_file"
    [[ -f "$so_file" ]] && rm -f "$so_file"

    log_ok "Extension '${ext}' removed. Restart PHP-FPM to apply."
}

# Install Redis server (standalone, not PHP extension)
install_redis_server() {
    log_info "=== Installing Redis ${REDIS_VER} ==="

    download_src "Redis" "$REDIS_URL"
    tar_cd "redis-${REDIS_VER}.tar.gz" "redis-${REDIS_VER}"

    make -j"$(nproc)" PREFIX=/usr/local/redis install 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Redis build failed"

    mkdir -p /usr/local/redis/etc /usr/local/redis/var
    cp redis.conf /usr/local/redis/etc/redis.conf

    # Basic tuning
    sed -i 's/^daemonize no/daemonize no/' /usr/local/redis/etc/redis.conf
    sed -i 's|^dir \./|dir /usr/local/redis/var|' /usr/local/redis/etc/redis.conf
    sed -i 's/^# bind 127.0.0.1/bind 127.0.0.1/' /usr/local/redis/etc/redis.conf

    cp "${cur_dir}/systemd/redis.service" /etc/systemd/system/redis.service
    systemctl daemon-reload
    systemctl enable redis

    ln -sf /usr/local/redis/bin/redis-cli /usr/bin/redis-cli
    ln -sf /usr/local/redis/bin/redis-server /usr/bin/redis-server

    log_ok "Redis ${REDIS_VER} installed."
}

# Install Memcached server
install_memcached_server() {
    log_info "=== Installing Memcached ${MEMCACHED_VER} ==="

    download_src "Memcached" "$MEMCACHED_URL"
    tar_cd "memcached-${MEMCACHED_VER}.tar.gz" "memcached-${MEMCACHED_VER}"

    ./configure --prefix=/usr/local/memcached --enable-sasl
    make_install

    ln -sf /usr/local/memcached/bin/memcached /usr/bin/memcached

    log_ok "Memcached ${MEMCACHED_VER} installed."
}
