#!/usr/bin/env bash
# lib/nginx.sh — Nginx compile and install
# shellcheck disable=SC2154  # Configuration and cur_dir are provided by sourced files.

install_nginx() {
    local mode="${1:-install}"
    [[ "$mode" = 'install' || "$mode" = 'upgrade' ]] || die "Invalid Nginx install mode: ${mode}"
    log_info "=== ${mode^}ing Nginx ${NGINX_VER} ==="

    id -u www &>/dev/null || useradd -s /sbin/nologin -M www

    download_src "Nginx" "$NGINX_URL" "$NGINX_SHA256"

    if [[ "${Enable_Nginx_Openssl}" = 'y' ]]; then
        download_src "OpenSSL" "$OPENSSL_URL" "$OPENSSL_SHA256"
        local patch_index
        for patch_index in "${!OPENSSL_PATCH_URLS[@]}"; do
            download_src "OpenSSL security patch $((patch_index + 1))" \
                "${OPENSSL_PATCH_URLS[$patch_index]}" \
                "${OPENSSL_PATCH_SHA256S[$patch_index]}"
        done
    fi

    if [[ "${Memory_Allocator}" = 'jemalloc' ]]; then
        _install_jemalloc "$mode"
    fi

    if [[ "${Enable_Nginx_Lua}" = 'y' ]]; then
        _install_nginx_lua_deps
    fi

    tar_cd "nginx-${NGINX_VER}.tar.gz" "nginx-${NGINX_VER}"

    local nginx_configure_args=(
        --user=www --group=www
        --prefix=/usr/local/nginx
        --with-http_stub_status_module
        --with-http_ssl_module
        --with-http_v2_module
        --with-http_gzip_static_module
        --with-http_sub_module
        --with-http_flv_module
        --with-http_mp4_module
        --with-http_realip_module
        --with-http_auth_request_module
        --with-http_secure_link_module
        --with-http_xslt_module
        --with-stream
        --with-stream_ssl_module
        --with-stream_realip_module
    )

    if [[ "${Enable_Nginx_Openssl}" = 'y' ]]; then
        _prepare_nginx_openssl
        cd "${cur_dir}/src/nginx-${NGINX_VER}" || die "Cannot enter Nginx source directory"
        nginx_configure_args+=( "--with-openssl=${cur_dir}/src/openssl-${OPENSSL_VER}" )
        nginx_configure_args+=( "--with-openssl-opt=no-shared no-threads no-tests" )
        nginx_configure_args+=( --with-http_v3_module )
    fi

    if [[ "${Memory_Allocator}" = 'jemalloc' ]]; then
        nginx_configure_args+=( "--with-ld-opt=-ljemalloc" )
    fi

    if [[ "${Enable_Nginx_Lua}" = 'y' ]]; then
        export LUAJIT_LIB=/usr/local/lib
        export LUAJIT_INC=/usr/local/include/luajit-2.1
        nginx_configure_args+=(
            "--add-module=${cur_dir}/src/ngx_devel_kit-${NGX_DEVEL_KIT_VER}"
            "--add-module=${cur_dir}/src/lua-nginx-module-${LUA_NGINX_MODULE_VER}"
        )
    fi

    if [[ -n "${Nginx_Modules_Options}" ]]; then
        local -a nginx_extra_args=()
        read -r -a nginx_extra_args <<< "${Nginx_Modules_Options}"
        nginx_configure_args+=( "${nginx_extra_args[@]}" )
    fi

    cd "${cur_dir}/src/nginx-${NGINX_VER}" || die "Cannot enter Nginx source directory"
    export PKG_CONFIG_PATH="/usr/lib/${ARCH}-linux-gnu/pkgconfig:/usr/share/pkgconfig"

    ./configure "${nginx_configure_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Nginx configure failed"

    if [[ "$mode" = 'upgrade' ]]; then
        make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
        [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Nginx build failed"
        install -m 0755 objs/nginx /usr/local/nginx/sbin/nginx.new
        /usr/local/nginx/sbin/nginx.new -t -p /usr/local/nginx/ -c conf/nginx.conf \
            2>&1 | tee -a "$LOG_FILE"
        [[ ${PIPESTATUS[0]} -eq 0 ]] || {
            rm -f /usr/local/nginx/sbin/nginx.new
            die "New Nginx binary failed configuration validation"
        }
        mv /usr/local/nginx/sbin/nginx.new /usr/local/nginx/sbin/nginx
    else
        make_install
        mkdir -p /usr/local/nginx/conf/{vhost,ssl} /home/wwwlogs
        _deploy_nginx_conf
        cp "${cur_dir}/systemd/nginx.service" /etc/systemd/system/nginx.service
        systemctl daemon-reload
        systemctl enable nginx
    fi

    ln -sf /usr/local/nginx/sbin/nginx /usr/bin/nginx
    record_installed_version NGINX "$NGINX_VER"
    if [[ "${Enable_Nginx_Openssl}" = 'y' ]]; then
        record_installed_version OPENSSL "$OPENSSL_TARGET_LABEL"
    fi
    [[ "${Memory_Allocator}" = 'jemalloc' ]] && record_installed_version JEMALLOC "$JEMALLOC_VER"
    [[ "${Enable_Nginx_Lua}" = 'y' ]] && {
        record_installed_version LUAJIT "$LUAJIT_VER"
        record_installed_version LUA_NGINX_MODULE "$LUA_NGINX_MODULE_VER"
        record_installed_version NGX_DEVEL_KIT "$NGX_DEVEL_KIT_VER"
    }

    log_ok "Nginx ${NGINX_VER} ${mode} completed."
}

_prepare_nginx_openssl() {
    cd "${cur_dir}/src" || die "Cannot enter source directory"
    tar_cd "openssl-${OPENSSL_VER}.tar.gz" "openssl-${OPENSSL_VER}"

    local patch_index patch_file
    for patch_index in "${!OPENSSL_PATCH_URLS[@]}"; do
        patch_file="$(basename "${OPENSSL_PATCH_URLS[$patch_index]}")"
        patch --batch --forward -p1 < "${cur_dir}/src/${patch_file}" 2>&1 | tee -a "$LOG_FILE"
        [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Failed to apply OpenSSL patch: ${patch_file}"
    done
    log_ok "OpenSSL ${OPENSSL_VER} security patch set ${OPENSSL_SECURITY_PATCHSET} applied."
}

_install_jemalloc() {
    local mode="${1:-install}"
    if [[ "$mode" != 'upgrade' && -f /usr/local/lib/libjemalloc.so ]]; then
        log_info "jemalloc already installed, skipping."
        return 0
    fi
    download_src "jemalloc" "$JEMALLOC_URL" "$JEMALLOC_SHA256"
    tar_cd "jemalloc-${JEMALLOC_VER}.tar.bz2" "jemalloc-${JEMALLOC_VER}"
    ./configure --prefix=/usr/local
    make_install
    ldconfig
    record_installed_version JEMALLOC "$JEMALLOC_VER"
    log_ok "jemalloc ${JEMALLOC_VER} installed."
}

_install_nginx_lua_deps() {
    download_src "LuaJIT" "$LUAJIT_URL" "$LUAJIT_SHA256"
    download_src "lua-nginx-module" "$LUA_NGINX_MODULE_URL" "$LUA_NGINX_MODULE_SHA256"
    download_src "ngx_devel_kit" "$NGX_DEVEL_KIT_URL" "$NGX_DEVEL_KIT_SHA256"
    # Build LuaJIT
    cd "${cur_dir}/src" || die "Cannot enter source directory"
    tar zxf "v${LUAJIT_VER}.tar.gz"
    cd "luajit2-${LUAJIT_VER}" || die "Cannot enter LuaJIT source directory"
    make -j"$(nproc)" PREFIX=/usr/local
    make install PREFIX=/usr/local
    ldconfig

    # Extract modules
    cd "${cur_dir}/src" || die "Cannot enter source directory"
    tar zxf "v${LUA_NGINX_MODULE_VER}.tar.gz"
    tar zxf "v${NGX_DEVEL_KIT_VER}.tar.gz"
}

_deploy_nginx_conf() {
    # Generate nginx.conf from template with tuning params
    sed -e "s|{{WORKER_PROCESSES}}|${NGINX_WORKER_PROCESSES}|g" \
        -e "s|{{WORKER_CONNECTIONS}}|${NGINX_WORKER_CONNECTIONS}|g" \
        -e "s|{{OPEN_FILE_CACHE_MAX}}|${NGINX_OPEN_FILE_CACHE_MAX}|g" \
        "${cur_dir}/conf/nginx/nginx.conf" > /usr/local/nginx/conf/nginx.conf

    # Copy additional config files
    for f in fastcgi.conf proxy.conf security_headers.conf mime.types; do
        [[ -f "${cur_dir}/conf/nginx/${f}" ]] && cp "${cur_dir}/conf/nginx/${f}" /usr/local/nginx/conf/
    done

    # Copy rewrite rules
    [[ -d "${cur_dir}/conf/rewrite" ]] && cp -r "${cur_dir}/conf/rewrite" /usr/local/nginx/conf/

    # Default catch-all: self-signed cert + reject unknown hosts
    _setup_default_catch_all

    # Default vhost
    local default_dir="${Default_Website_Dir:-/home/wwwroot/default}"
    mkdir -p "$default_dir"
    [[ -f "${cur_dir}/conf/nginx/default_vhost.conf" ]] && \
        sed "s|{{DEFAULT_DIR}}|${default_dir}|g" "${cur_dir}/conf/nginx/default_vhost.conf" \
            > /usr/local/nginx/conf/vhost/default.conf

    # Default index page
    cat > "${default_dir}/index.html" <<'INDEXEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Server Ready</title></head>
<body><h1>It works!</h1><p>LNMP stack is running.</p></body></html>
INDEXEOF
}

_setup_default_catch_all() {
    local ssl_dir="/usr/local/nginx/conf/ssl"
    mkdir -p "$ssl_dir"

    # Generate self-signed cert for default server (reject unknown hosts)
    if [[ ! -f "${ssl_dir}/default.crt" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${ssl_dir}/default.key" \
            -out "${ssl_dir}/default.crt" \
            -subj "/CN=default.invalid" 2>/dev/null
        log_info "Generated self-signed cert for default catch-all server."
    fi

    # Generate DH parameters for stronger SSL
    if [[ ! -f "${ssl_dir}/dhparam.pem" ]]; then
        log_info "Generating DH parameters (2048-bit)... this may take a moment."
        openssl dhparam -out "${ssl_dir}/dhparam.pem" 2048 2>/dev/null
        log_ok "DH parameters generated."
    fi

    # Deploy catch-all config (loaded before vhost/* via include order)
    cp "${cur_dir}/conf/nginx/default_catch_all.conf" /usr/local/nginx/conf/default_catch_all.conf
}
