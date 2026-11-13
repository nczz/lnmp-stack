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

# Extension registry: name -> URL, digest, version, configure options, packages.
declare -gA EXT_URL_VAR EXT_SHA_VAR EXT_VER_VAR EXT_CONFIGURE EXT_DEPS || true

EXT_URL_VAR[redis]='REDIS_EXT_URL'
EXT_SHA_VAR[redis]='REDIS_EXT_SHA256'
EXT_VER_VAR[redis]='REDIS_EXT_VER'
EXT_CONFIGURE[redis]=''
EXT_DEPS[redis]=''

EXT_URL_VAR[imagick]='IMAGICK_URL'
EXT_SHA_VAR[imagick]='IMAGICK_SHA256'
EXT_VER_VAR[imagick]='IMAGICK_VER'
EXT_CONFIGURE[imagick]=''
EXT_DEPS[imagick]='libmagickwand-dev'

EXT_URL_VAR[apcu]='APCU_URL'
EXT_SHA_VAR[apcu]='APCU_SHA256'
EXT_VER_VAR[apcu]='APCU_VER'
EXT_CONFIGURE[apcu]=''
EXT_DEPS[apcu]=''

EXT_URL_VAR[swoole]='SWOOLE_URL'
EXT_SHA_VAR[swoole]='SWOOLE_SHA256'
EXT_VER_VAR[swoole]='SWOOLE_VER'
EXT_CONFIGURE[swoole]='--enable-openssl --enable-sockets --enable-mysqlnd --enable-http2'
EXT_DEPS[swoole]='libssl-dev libcurl4-openssl-dev'

EXT_URL_VAR[memcached]='MEMCACHED_EXT_URL'
EXT_SHA_VAR[memcached]='MEMCACHED_EXT_SHA256'
EXT_VER_VAR[memcached]='MEMCACHED_EXT_VER'
EXT_CONFIGURE[memcached]='--with-libmemcached-dir=/usr --disable-memcached-sasl'
EXT_DEPS[memcached]='libmemcached-dev'

# IMAP was unbundled from PHP core in PHP 8.4.
EXT_URL_VAR[imap]='IMAP_EXT_URL'
EXT_SHA_VAR[imap]='IMAP_EXT_SHA256'
EXT_VER_VAR[imap]='IMAP_EXT_VER'
EXT_CONFIGURE[imap]='--with-imap=/usr --with-imap-ssl --with-kerberos'
EXT_DEPS[imap]='libc-client2007e-dev libkrb5-dev libssl-dev'

# List available extensions
list_extensions() {
    echo "Available extensions:"
    for ext in "${!EXT_URL_VAR[@]}"; do
        local status="not installed"
        if $PHP_BIN -m 2>/dev/null | grep -i "^${ext}$" >/dev/null; then
            status="installed"
        fi
        printf "  %-15s [%s]\n" "$ext" "$status"
    done
}

_php_extension_directive_exists() {
    local ext="$1" root file line key value name
    local -a files=()
    root="${PHP_INI_ROOT:-$(dirname "$PHP_INI_SCAN_DIR")}"
    [[ -f "${root}/php.ini" ]] && files+=("${root}/php.ini")
    shopt -s nullglob
    files+=("${PHP_INI_SCAN_DIR}/"*.ini)
    shopt -u nullglob
    for file in "${files[@]}"; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "$line" = \;* || "$line" = \#* || "$line" != *=* ]] && continue
            key="${line%%=*}"
            key="${key%"${key##*[![:space:]]}"}"
            [[ "$key" = extension ]] || continue
            value="${line#*=}"
            value="${value%%;*}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"
            name="${value##*/}"
            name="${name%%.so*}"
            [[ "$name" = "$ext" ]] && return 0
        done < "$file"
    done
    return 1
}

_enable_php_extension_ini() {
    local ext="$1" ini_file
    ini_file="${PHP_INI_SCAN_DIR}/${ext}.ini"
    if _php_extension_directive_exists "$ext"; then
        log_info "Preserving existing PHP extension activation and tuning for: ${ext}"
        return 0
    fi
    printf 'extension=%s.so\n' "$ext" > "$ini_file" \
        || die "Cannot enable PHP extension ${ext}: ${ini_file}"
}

# Install a PHP extension by name
# Usage: install_extension <name>
install_extension() {
    local ext="$1" force="${2:-n}"
    _init_php_ext_dir

    [[ -n "${EXT_URL_VAR[$ext]+x}" ]] || die "Unknown extension: ${ext}. Run with 'list' to see available."

    if [[ "$force" != 'y' ]] && $PHP_BIN -m 2>/dev/null | grep -i "^${ext}$" >/dev/null; then
        log_warn "Extension '${ext}' is already loaded. Skipping."
        return 0
    fi

    log_info "=== Installing PHP extension: ${ext} ==="

    # Install system dependencies
    local deps="${EXT_DEPS[$ext]}"
    if [[ -n "$deps" ]]; then
        local -a dep_args=()
        read -r -a dep_args <<< "$deps"
        log_info "Installing dependencies: ${deps}"
        wait_apt_lock
        apt-get -y install "${dep_args[@]}" 2>&1 | tee -a "$LOG_FILE"
        [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Failed to install dependencies for ${ext}: ${deps}"
    fi

    # Download the pinned PECL release.
    local url_var="${EXT_URL_VAR[$ext]}"
    local sha_var="${EXT_SHA_VAR[$ext]}"
    local ver_var="${EXT_VER_VAR[$ext]}"
    local url="${!url_var}" sha256="${!sha_var}" version="${!ver_var}"
    [[ -n "$url" && -n "$sha256" && -n "$version" ]] || die "Incomplete source metadata for extension: ${ext}"

    local filename
    filename="$(basename "$url")"
    download_src "${ext}" "$url" "$sha256"
    # Extract
    cd "${cur_dir:?lib/common.sh must be sourced before lib/extensions.sh}/src" || die "Cannot cd to ${cur_dir}/src"
    local dirname="${filename%.tgz}"
    dirname="${dirname%.tar.gz}"
    [[ -d "$dirname" ]] && rm -rf "$dirname"
    tar zxf "$filename"
    cd "$dirname" || die "Cannot cd to ${dirname}"

    # Build
    $PHPIZE
    local configure_opts="${EXT_CONFIGURE[$ext]}"
    local -a configure_args=( --with-php-config="$PHP_CONFIG" )
    if [[ -n "$configure_opts" ]]; then
        local -a configure_extra_args=()
        read -r -a configure_extra_args <<< "$configure_opts"
        configure_args+=( "${configure_extra_args[@]}" )
    fi
    ./configure "${configure_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Configure failed for ${ext}"

    make_install

    # Enable
    _enable_php_extension_ini "$ext"

    # Verify (avoid grep -q which triggers SIGPIPE under pipefail).
    if $PHP_BIN -m 2>/dev/null | grep -i "^${ext}$" >/dev/null; then
        local state_key="PHP_EXT_${ext^^}"
        record_installed_version "$state_key" "$version"
        log_ok "Extension '${ext}' ${version} installed and loaded."
    else
        die "Extension '${ext}' installed but failed to load. Check: php -m"
    fi
}

install_configured_php_extensions() {
    [[ -n "${PHP_Extensions_Install:-}" ]] || return 0
    log_info "Installing PHP extensions: ${PHP_Extensions_Install}"
    local ext
    for ext in ${PHP_Extensions_Install}; do
        install_extension "$ext"
    done
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

# Install or upgrade Redis server (standalone, not PHP extension).
install_redis_server() {
    local mode="${1:-install}"
    log_info "=== ${mode^}ing Redis ${REDIS_VER} ==="

    download_src "Redis" "$REDIS_URL" "$REDIS_SHA256"
    tar_cd "redis-${REDIS_VER}.tar.gz" "redis-${REDIS_VER}"

    # Redis 8.10's default target builds Redis Stack modules. This project
    # deploys the standalone server, so select the upstream core-only target.
    make -j"$(nproc)" build redis 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Redis build failed"
    if [[ "$mode" = 'upgrade' ]]; then
        systemctl stop redis || die "Cannot stop Redis for deployment."
    fi
    make PREFIX=/usr/local/redis install 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Redis installation failed"

    if [[ "$mode" = 'install' ]]; then
        mkdir -p /usr/local/redis/etc /usr/local/redis/var
        cp redis.conf /usr/local/redis/etc/redis.conf

        # The core-only install does not deploy bundled Redis Stack modules.
        sed -i -E 's|^([[:space:]]*loadmodule[[:space:]]+\./modules/.*)|# \1|' /usr/local/redis/etc/redis.conf
        sed -i 's/^daemonize no/daemonize no/' /usr/local/redis/etc/redis.conf
        sed -i 's|^dir \./|dir /usr/local/redis/var|' /usr/local/redis/etc/redis.conf
        sed -i 's/^# bind 127.0.0.1/bind 127.0.0.1/' /usr/local/redis/etc/redis.conf

        cp "${cur_dir}/systemd/redis.service" /etc/systemd/system/redis.service
        systemctl daemon-reload
        systemctl enable redis
    fi

    ln -sf /usr/local/redis/bin/redis-cli /usr/bin/redis-cli
    ln -sf /usr/local/redis/bin/redis-server /usr/bin/redis-server
    record_installed_version REDIS "$REDIS_VER"
    log_ok "Redis ${REDIS_VER} ${mode} completed."
}

# Install or upgrade Memcached server.
install_memcached_server() {
    local mode="${1:-install}"
    log_info "=== ${mode^}ing Memcached ${MEMCACHED_VER} ==="

    wait_apt_lock
    apt-get -y install --no-install-recommends libevent-dev libsasl2-dev 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Failed to install Memcached build dependencies"

    download_src "Memcached" "$MEMCACHED_URL" "$MEMCACHED_SHA256"
    tar_cd "memcached-${MEMCACHED_VER}.tar.gz" "memcached-${MEMCACHED_VER}"

    ./configure --prefix=/usr/local/memcached --enable-sasl 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Memcached configure failed"
    make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Memcached build failed"
    if [[ "$mode" = 'upgrade' ]]; then
        systemctl stop memcached || die "Cannot stop Memcached for deployment."
    fi
    make install 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Memcached installation failed"
    ln -sf /usr/local/memcached/bin/memcached /usr/bin/memcached
    if [[ "$mode" = 'install' ]]; then
        cp "${cur_dir}/systemd/memcached.service" /etc/systemd/system/memcached.service
        systemctl daemon-reload
        systemctl enable memcached
    fi

    record_installed_version MEMCACHED "$MEMCACHED_VER"
    log_ok "Memcached ${MEMCACHED_VER} ${mode} completed."
}
