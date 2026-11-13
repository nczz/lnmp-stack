#!/usr/bin/env bash
# lib/upgrade.sh — Installed-version inventory and rollback-aware component upgrades

UPGRADE_COMPONENTS=(
    nginx php db redis memcached
    ext:redis ext:imagick ext:apcu ext:swoole ext:memcached ext:imap
    composer wp-cli phpmyadmin acme
)

_upgrade_state_or_empty() {
    read_installed_version "$1" 2>/dev/null || true
}

_upgrade_runtime_version() {
    local component="$1" output=""
    case "$component" in
        nginx)
            [[ -x /usr/local/nginx/sbin/nginx ]] || return 0
            output=$(/usr/local/nginx/sbin/nginx -v 2>&1 || true)
            printf '%s' "${output##*/}"
            ;;
        php)
            [[ -x /usr/local/php/bin/php ]] || return 0
            /usr/local/php/bin/php -r 'echo PHP_VERSION;' 2>/dev/null || true
            ;;
        db)
            if [[ -x /usr/local/mariadb/bin/mariadb ]]; then
                output=$(/usr/local/mariadb/bin/mariadb --version 2>/dev/null || true)
                printf '%s\n' "$output" | sed -n \
                    -e 's/.* Distrib \([0-9][0-9.]*\).*/\1/p' \
                    -e 's/.* from \([0-9][0-9.]*\)-MariaDB.*/\1/p'
            elif [[ -x /usr/local/mysql/bin/mysql ]]; then
                output=$(/usr/local/mysql/bin/mysql --version 2>/dev/null || true)
                printf '%s\n' "$output" | sed -n 's/.*[[:space:]]Ver[[:space:]]\([0-9][0-9.]*\).*/\1/p'
            fi
            ;;
        redis)
            [[ -x /usr/local/redis/bin/redis-server ]] || return 0
            output=$(/usr/local/redis/bin/redis-server --version 2>/dev/null || true)
            printf '%s\n' "$output" | sed -n 's/.*v=\([^ ]*\).*/\1/p'
            ;;
        memcached)
            [[ -x /usr/local/memcached/bin/memcached ]] || return 0
            /usr/local/memcached/bin/memcached -h 2>/dev/null | sed -n '1s/^memcached //p'
            ;;
        composer)
            [[ -x /usr/local/bin/composer && -x /usr/local/php/bin/php ]] || return 0
            /usr/local/php/bin/php /usr/local/bin/composer --version --no-ansi 2>/dev/null | awk '{print $3}'
            ;;
        wp-cli)
            [[ -x /usr/local/bin/wp ]] || return 0
            output=$(/usr/local/bin/wp cli version --allow-root 2>/dev/null || true)
            printf '%s' "${output##* }"
            ;;
        phpmyadmin)
            local dest="${Default_Website_Dir:-/home/wwwroot/default}/phpmyadmin"
            [[ -d "$dest" ]] || return 0
            output=$(_upgrade_state_or_empty PHPMYADMIN)
            if [[ -z "$output" ]]; then
                local version_file="${dest}/libraries/classes/Version.php"
                [[ -r "$version_file" ]] && output=$(sed -n "s/.*VERSION[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$version_file" | head -n 1)
            fi
            printf '%s' "${output:-installed-version-unknown}"
            ;;
        acme)
            [[ -x /usr/local/acme.sh/acme.sh ]] || return 0
            output=$(/usr/local/acme.sh/acme.sh --home /usr/local/acme.sh --version 2>/dev/null | sed -n '$s/^v//p')
            [[ -n "$output" ]] || output=$(_upgrade_state_or_empty ACME_SH)
            printf '%s' "$output"
            ;;
        ext:*)
            local ext="${component#ext:}"
            [[ -x /usr/local/php/bin/php ]] || return 0
            /usr/local/php/bin/php -r "echo phpversion('${ext}') ?: '';" 2>/dev/null || true
            ;;
    esac
}

_upgrade_target_version() {
    case "$1" in
        nginx) printf '%s' "$NGINX_VER" ;;
        php) printf '%s' "$PHP_VER" ;;
        db)
            if [[ -x /usr/local/mariadb/bin/mariadb ]]; then
                printf '%s' "$MARIADB_VER"
            elif [[ -x /usr/local/mysql/bin/mysql ]]; then
                printf '%s' "$MYSQL_VER"
            elif [[ "${DB_Type:-mariadb}" = mariadb ]]; then
                printf '%s' "$MARIADB_VER"
            else
                printf '%s' "$MYSQL_VER"
            fi
            ;;
        redis) printf '%s' "$REDIS_VER" ;;
        memcached) printf '%s' "$MEMCACHED_VER" ;;
        ext:redis) printf '%s' "$REDIS_EXT_VER" ;;
        ext:imagick) printf '%s' "$IMAGICK_VER" ;;
        ext:apcu) printf '%s' "$APCU_VER" ;;
        ext:swoole) printf '%s' "$SWOOLE_VER" ;;
        ext:memcached) printf '%s' "$MEMCACHED_EXT_VER" ;;
        ext:imap) printf '%s' "$IMAP_EXT_VER" ;;
        composer) printf '%s' "$COMPOSER_VER" ;;
        wp-cli) printf '%s' "$WP_CLI_VER" ;;
        phpmyadmin) printf '%s' 'removed (no fixed release)' ;;
        acme) printf '%s' "$ACME_SH_VER" ;;
        *) return 1 ;;
    esac
}

_upgrade_version_status() {
    local installed="$1" target="$2" first
    if [[ -z "$installed" ]]; then
        printf 'MISSING'
    elif [[ "$installed" = "$target" ]]; then
        printf 'CURRENT'
    else
        first=$(printf '%s\n%s\n' "$installed" "$target" | sort -V | head -n 1)
        if [[ "$first" = "$installed" ]]; then
            printf 'OUTDATED'
        else
            printf 'AHEAD'
        fi
    fi
}

_upgrade_component_status() {
    local component="$1" installed target status openssl_installed
    installed=$(_upgrade_runtime_version "$component")
    target=$(_upgrade_target_version "$component")

    if [[ "$component" = phpmyadmin ]]; then
        [[ -z "$installed" ]] && status=CURRENT || status=OUTDATED
    else
        status=$(_upgrade_version_status "$installed" "$target")
    fi

    if [[ "$component" = nginx && "$status" = CURRENT && "${Enable_Nginx_Openssl:-n}" = y ]]; then
        openssl_installed=$(_upgrade_state_or_empty OPENSSL)
        [[ "$openssl_installed" = "$OPENSSL_TARGET_LABEL" ]] || status=OUTDATED
    elif [[ "$component" = php && "$status" = CURRENT ]]; then
        _upgrade_php_security_hardened || status=OUTDATED
        _upgrade_generated_phpinfo_absent || status=OUTDATED
    fi
    printf '%s' "$status"
}

_upgrade_nginx_openssl_version() {
    local version output
    version=$(_upgrade_state_or_empty OPENSSL)
    if [[ -z "$version" && -x /usr/local/nginx/sbin/nginx ]]; then
        output=$(/usr/local/nginx/sbin/nginx -V 2>&1 || true)
        version=$(printf '%s\n' "$output" | sed -n 's/.*built with OpenSSL \([^ ]*\).*/\1/p')
    fi
    printf '%s' "$version"
}

_upgrade_php_security_hardened() {
    [[ -x /usr/local/php/bin/php ]] || return 1
    /usr/local/php/bin/php -r \
        'exit(ini_get("session.upload_progress.enabled") === "0" ? 0 : 1);' \
        >/dev/null 2>&1
}

_upgrade_generated_phpinfo_absent() {
    local phpinfo="${Default_Website_Dir:-/home/wwwroot/default}/phpinfo.php"
    ! { [[ -f "$phpinfo" ]] \
        && [[ "$(wc -l < "$phpinfo")" -eq 1 ]] \
        && grep -Fqx '<?php phpinfo(); ?>' "$phpinfo"; }
}

upgrade_plan() {
    local component installed target status action openssl_installed
    printf '%-16s %-32s %-42s %-10s %s\n' COMPONENT INSTALLED TARGET STATUS ACTION
    printf '%-16s %-32s %-42s %-10s %s\n' '----------------' '--------------------------------' '------------------------------------------' '----------' '-----'
    for component in "${UPGRADE_COMPONENTS[@]}"; do
        installed=$(_upgrade_runtime_version "$component")
        target=$(_upgrade_target_version "$component")
        status=$(_upgrade_component_status "$component")
        action='-'
        [[ "$status" = OUTDATED ]] && action="lnmp upgrade apply ${component}"
        if [[ "$component" = nginx && "${Enable_Nginx_Openssl:-n}" = y ]]; then
            openssl_installed=$(_upgrade_nginx_openssl_version)
            [[ -n "$installed" ]] && installed="${installed} / OpenSSL ${openssl_installed:-untracked}"
            target="${target} / OpenSSL ${OPENSSL_TARGET_LABEL}"
        elif [[ "$component" = php ]]; then
            target="${target} / upload-progress=off,phpinfo=absent"
        fi
        printf '%-16s %-32s %-42s %-10s %s\n' \
            "$component" "${installed:--}" "$target" "$status" "$action"
    done
    printf '\nSecurity baseline: %s\n' "$SECURITY_BASELINE_DATE"
}

_upgrade_load_build_libraries() {
    [[ -n "${_UPGRADE_BUILD_LIBS_LOADED:-}" ]] && return 0
    source "${cur_dir}/lib/detect.sh"
    source "${cur_dir}/lib/deps.sh"
    source "${cur_dir}/lib/nginx.sh"
    source "${cur_dir}/lib/mysql.sh"
    source "${cur_dir}/lib/php.sh"
    source "${cur_dir}/lib/extensions.sh"
    _UPGRADE_BUILD_LIBS_LOADED=1

    detect_os
    check_os_support
    detect_hardware
    calc_tuning_params
}

_upgrade_backup_root() {
    local root
    mkdir -p /var/backups/lnmp || die "Cannot create /var/backups/lnmp."
    root=$(mktemp -d "/var/backups/lnmp/$(date +%Y%m%d%H%M%S)-XXXXXX") \
        || die "Cannot create an upgrade backup directory."
    chmod 0700 "$root" || die "Cannot protect upgrade backup directory: ${root}"
    printf '%s' "$root"
}

_upgrade_save_version_state() {
    local backup_root="$1"
    if [[ -f "$LNMP_VERSION_STATE" ]]; then
        cp -a "$LNMP_VERSION_STATE" "${backup_root}/installed-versions" \
            || die "Cannot back up installed-version state."
    else
        touch "${backup_root}/version-state-was-absent"
    fi
}

_upgrade_restore_version_state() {
    local backup_root="$1"
    if [[ -f "${backup_root}/installed-versions" ]]; then
        mkdir -p "$LNMP_STATE_DIR"
        cp -a "${backup_root}/installed-versions" "$LNMP_VERSION_STATE"
    else
        rm -f "$LNMP_VERSION_STATE"
    fi
}

_upgrade_nginx() {
    local backup_root backup_bin
    backup_root=$(_upgrade_backup_root)
    backup_bin="${backup_root}/nginx"
    cp -a /usr/local/nginx/sbin/nginx "$backup_bin" \
        || die "Cannot back up the current Nginx binary."
    _upgrade_save_version_state "$backup_root"
    if ! ( install_nginx upgrade ); then
        cp -a "$backup_bin" /usr/local/nginx/sbin/nginx
        _upgrade_restore_version_state "$backup_root"
        return 1
    fi
    if ! /usr/local/nginx/sbin/nginx -t || ! systemctl restart nginx; then
        log_err "Nginx validation/restart failed; restoring previous binary."
        cp -a "$backup_bin" /usr/local/nginx/sbin/nginx
        _upgrade_restore_version_state "$backup_root"
        systemctl restart nginx || true
        return 1
    fi
    log_ok "Nginx upgrade deployed. Previous binary: ${backup_bin}"
}

_upgrade_php() {
    local backup_root backup_php ext
    local -a installed_extensions=()
    backup_root=$(_upgrade_backup_root)
    backup_php="${backup_root}/php"
    cp -a /usr/local/php "$backup_php" \
        || die "Cannot back up the current PHP prefix."
    _upgrade_save_version_state "$backup_root"

    for ext in redis imagick apcu swoole memcached imap; do
        [[ -n "$(_upgrade_runtime_version "ext:${ext}")" ]] && installed_extensions+=("$ext")
    done

    if ( install_php upgrade && for ext in "${installed_extensions[@]}"; do install_extension "$ext" y; done ); then
        if /usr/local/php/sbin/php-fpm -t && systemctl start php-fpm; then
            log_ok "PHP upgrade deployed. Previous prefix: ${backup_php}"
            return 0
        fi
    fi

    log_err "PHP upgrade failed; restoring previous prefix."
    systemctl stop php-fpm 2>/dev/null || true
    rm -rf /usr/local/php
    mv "$backup_php" /usr/local/php
    _upgrade_restore_version_state "$backup_root"
    ln -sf /usr/local/php/bin/php /usr/bin/php
    ln -sf /usr/local/php/bin/phpize /usr/bin/phpize
    ln -sf /usr/local/php/bin/php-config /usr/bin/php-config
    ln -sf /usr/local/php/bin/pecl /usr/bin/pecl
    ln -sf /usr/local/php/sbin/php-fpm /usr/bin/php-fpm
    systemctl start php-fpm || true
    return 1
}

_upgrade_redis_wait() {
    local i
    for ((i = 0; i < 120; i++)); do
        /usr/local/redis/bin/redis-cli ping 2>/dev/null | grep -qx PONG && return 0
        systemctl is-failed --quiet redis && return 1
        sleep 1
    done
    return 1
}

_upgrade_redis() {
    local backup_root backup_bin
    backup_root=$(_upgrade_backup_root)
    backup_bin="${backup_root}/redis-bin"
    cp -a /usr/local/redis/bin "$backup_bin" \
        || die "Cannot back up the current Redis binaries."
    _upgrade_save_version_state "$backup_root"
    if ( install_redis_server upgrade ) && systemctl restart redis \
        && _upgrade_redis_wait; then
        log_ok "Redis upgrade deployed. Previous binaries: ${backup_bin}"
        return 0
    fi
    log_err "Redis upgrade failed; restoring previous binaries."
    rm -rf /usr/local/redis/bin
    mv "$backup_bin" /usr/local/redis/bin
    _upgrade_restore_version_state "$backup_root"
    systemctl restart redis || true
    return 1
}

_upgrade_memcached() {
    local backup_root backup_bin
    backup_root=$(_upgrade_backup_root)
    backup_bin="${backup_root}/memcached-bin"
    cp -a /usr/local/memcached/bin "$backup_bin" \
        || die "Cannot back up the current Memcached binaries."
    _upgrade_save_version_state "$backup_root"
    if ( install_memcached_server upgrade ) && systemctl restart memcached \
        && systemctl is-active --quiet memcached; then
        log_ok "Memcached upgrade deployed. Previous binaries: ${backup_bin}"
        return 0
    fi
    log_err "Memcached upgrade failed; restoring previous binaries."
    rm -rf /usr/local/memcached/bin
    mv "$backup_bin" /usr/local/memcached/bin
    _upgrade_restore_version_state "$backup_root"
    systemctl restart memcached || true
    return 1
}

_upgrade_db_wait() {
    local admin_bin="$1" i
    for ((i = 0; i < 60; i++)); do
        "$admin_bin" --defaults-extra-file=/root/.my.cnf ping &>/dev/null && return 0
        sleep 2
    done
    return 1
}

_upgrade_db() {
    _check_db_arch_support
    local engine service old_prefix data_dir url sha version archive stage extracted candidate
    if [[ -x /usr/local/mariadb/bin/mariadb ]]; then
        engine=mariadb
        service=mariadb
        old_prefix=/usr/local/mariadb
        data_dir="${MariaDB_Data_Dir:-/usr/local/mariadb/var}"
        url="$MARIADB_URL"
        sha="$MARIADB_SHA256"
        version="$MARIADB_VER"
    else
        engine=mysql
        service=mysql
        old_prefix=/usr/local/mysql
        data_dir="${MySQL_Data_Dir:-/usr/local/mysql/var}"
        url="$MYSQL_URL"
        sha="$MYSQL_SHA256"
        version="$MYSQL_VER"
    fi

    [[ -d "$old_prefix" && -d "$data_dir" ]] || die "Database prefix or data directory is missing."
    [[ -r /root/.my.cnf ]] || die "Database upgrade requires /root/.my.cnf for backup and validation."

    local backup_root logical_dump old_backup dump_bin internal_rel=''
    backup_root=$(_upgrade_backup_root)
    logical_dump="${backup_root}/all-databases.sql.gz"
    old_backup=$(mktemp -d "${old_prefix}.previous.$(date +%Y%m%d%H%M%S)-XXXXXX") \
        || die "Cannot reserve a database rollback path beside ${old_prefix}."
    rmdir "$old_backup" || die "Cannot prepare database rollback path: ${old_backup}"
    dump_bin="${old_prefix}/bin/mysqldump"
    [[ -x "$dump_bin" ]] || dump_bin="${old_prefix}/bin/mariadb-dump"
    [[ -x "$dump_bin" ]] || die "Database dump client not found under ${old_prefix}."

    log_info "Creating pre-upgrade logical backup: ${logical_dump}"
    "$dump_bin" --defaults-extra-file=/root/.my.cnf --all-databases \
        --single-transaction --routines --events --triggers | gzip -9 > "$logical_dump" \
        || die "Database logical backup failed; upgrade was not started."
    [[ -s "$logical_dump" ]] || die "Database logical backup is empty; upgrade was not started."

    download_src "${engine}" "$url" "$sha"
    archive="${cur_dir}/src/$(basename "$url")"
    stage=$(mktemp -d /usr/local/.lnmp-db-upgrade.XXXXXX)
    case "$archive" in
        *.tar.xz) tar -xJf "$archive" -C "$stage" ;;
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$stage" ;;
        *) rm -rf "$stage"; die "Unsupported database archive: ${archive}" ;;
    esac
    extracted=''
    for candidate in "$stage"/*; do
        [[ -d "$candidate" ]] && { extracted="$candidate"; break; }
    done
    [[ -n "$extracted" ]] || { rm -rf "$stage"; die "Database archive did not contain a directory."; }

    if [[ "$engine" = mysql ]]; then
        _fix_mysql_libs
        _verify_mysql_libs "${extracted}/bin/mysqld"
        _verify_mysql_libs "${extracted}/bin/mysql"
    fi

    case "$data_dir" in
        "${old_prefix}"/*) internal_rel="${data_dir#"${old_prefix}"/}" ;;
    esac

    systemctl stop "$service" || {
        rm -rf "$stage"
        die "Cannot stop ${service}; database binaries were not changed."
    }
    if ! mv "$old_prefix" "$old_backup" || ! mv "$extracted" "$old_prefix"; then
        [[ -d "$old_backup" && ! -d "$old_prefix" ]] && mv "$old_backup" "$old_prefix"
        systemctl start "$service" || true
        rm -rf "$stage"
        return 1
    fi

    local failed=0 admin_bin upgrade_bin
    if [[ -n "$internal_rel" ]]; then
        mkdir -p "$(dirname "${old_prefix}/${internal_rel}")" \
            && mv "${old_backup}/${internal_rel}" "${old_prefix}/${internal_rel}" \
            || failed=1
    fi
    chown -R mysql:mysql "$old_prefix" || failed=1
    chown -R mysql:mysql "$data_dir" || failed=1
    if [[ "$engine" = mariadb ]]; then
        ln -sfn /usr/local/mariadb /usr/local/mysql || failed=1
    fi
    ln -sf "${old_prefix}/bin/mysql" /usr/bin/mysql || failed=1
    ln -sf "${old_prefix}/bin/mysqldump" /usr/bin/mysqldump || failed=1
    ln -sf "${old_prefix}/bin/mysqladmin" /usr/bin/mysqladmin || failed=1
    ldconfig || failed=1

    admin_bin="${old_prefix}/bin/mysqladmin"
    if [[ $failed -ne 0 ]] || ! systemctl start "$service" || ! _upgrade_db_wait "$admin_bin"; then
        failed=1
    else
        if [[ "$engine" = mariadb && -x "${old_prefix}/bin/mariadb-upgrade" ]]; then
            upgrade_bin="${old_prefix}/bin/mariadb-upgrade"
            "$upgrade_bin" --defaults-extra-file=/root/.my.cnf --force || failed=1
        elif [[ -x "${old_prefix}/bin/mysql_upgrade" ]]; then
            upgrade_bin="${old_prefix}/bin/mysql_upgrade"
            "$upgrade_bin" --defaults-extra-file=/root/.my.cnf --force || failed=1
        fi
    fi

    if [[ $failed -eq 0 ]]; then
        record_installed_version "${engine^^}" "$version"
        rm -rf "$stage"
        log_ok "${engine} ${version} deployed. Logical dump: ${logical_dump}; previous binaries: ${old_backup}"
        return 0
    fi

    log_err "Database upgrade failed; restoring previous binaries and data."
    systemctl stop "$service" 2>/dev/null || true
    if [[ -n "$internal_rel" && -d "${old_prefix}/${internal_rel}" ]]; then
        mkdir -p "$(dirname "${old_backup}/${internal_rel}")"
        mv "${old_prefix}/${internal_rel}" "${old_backup}/${internal_rel}"
    fi
    rm -rf "$old_prefix"
    mv "$old_backup" "$old_prefix"
    [[ "$engine" = mariadb ]] && ln -sfn /usr/local/mariadb /usr/local/mysql
    systemctl start "$service" || true
    rm -rf "$stage"
    return 1
}

_upgrade_extension() {
    local ext="$1" backup_root ini_file so_file
    backup_root=$(_upgrade_backup_root)
    _init_php_ext_dir
    ini_file="${PHP_INI_SCAN_DIR}/${ext}.ini"
    so_file="${PHP_EXT_DIR}/${ext}.so"
    [[ -f "$ini_file" ]] && cp -a "$ini_file" "${backup_root}/${ext}.ini"
    [[ -f "$so_file" ]] && cp -a "$so_file" "${backup_root}/${ext}.so"
    _upgrade_save_version_state "$backup_root"

    if ( install_extension "$ext" y ) && systemctl restart php-fpm; then
        return 0
    fi
    log_err "PHP extension ${ext} upgrade failed; restoring previous module."
    [[ -f "${backup_root}/${ext}.ini" ]] && cp -a "${backup_root}/${ext}.ini" "$ini_file"
    [[ -f "${backup_root}/${ext}.so" ]] && cp -a "${backup_root}/${ext}.so" "$so_file"
    _upgrade_restore_version_state "$backup_root"
    systemctl restart php-fpm || true
    return 1
}

_upgrade_single_file_tool() {
    local tool="$1" path="$2" backup_root
    backup_root=$(_upgrade_backup_root)
    cp -a "$path" "${backup_root}/tool" || die "Cannot back up ${tool}."
    _upgrade_save_version_state "$backup_root"

    if [[ "$tool" = composer ]]; then
        ( _install_composer y ) && return 0
    else
        ( install_wp_cli y ) && return 0
    fi
    log_err "${tool} upgrade failed; restoring previous executable."
    cp -a "${backup_root}/tool" "$path"
    _upgrade_restore_version_state "$backup_root"
    return 1
}

_upgrade_remove_phpmyadmin() {
    local backup_root dest
    dest="${Default_Website_Dir:-/home/wwwroot/default}/phpmyadmin"
    [[ -d "$dest" ]] || {
        remove_installed_version PHPMYADMIN
        return 0
    }

    backup_root=$(_upgrade_backup_root)
    cp -a "$dest" "${backup_root}/phpmyadmin" \
        || die "Cannot back up legacy phpMyAdmin before removal."
    _upgrade_save_version_state "$backup_root"
    rm -rf "$dest" || {
        log_err "Cannot remove legacy phpMyAdmin; backup retained at ${backup_root}/phpmyadmin."
        return 1
    }
    remove_installed_version PHPMYADMIN
    log_ok "Removed vulnerable phpMyAdmin deployment. Protected backup: ${backup_root}/phpmyadmin"
}

_upgrade_acme() {
    local backup_root
    backup_root=$(_upgrade_backup_root)
    cp -a /usr/local/acme.sh "${backup_root}/acme.sh" || die "Cannot back up acme.sh."
    _upgrade_save_version_state "$backup_root"
    if bash "${cur_dir}/tools/ssl.sh" client-upgrade; then
        return 0
    fi
    log_err "acme.sh upgrade failed; restoring previous client and account data."
    rm -rf /usr/local/acme.sh
    mv "${backup_root}/acme.sh" /usr/local/acme.sh
    _upgrade_restore_version_state "$backup_root"
    return 1
}

_upgrade_one() {
    local component="$1"
    case "$component" in
        nginx) _upgrade_nginx ;;
        php) _upgrade_php ;;
        db) _upgrade_db ;;
        redis) _upgrade_redis ;;
        memcached) _upgrade_memcached ;;
        ext:*) _upgrade_extension "${component#ext:}" ;;
        composer) _upgrade_single_file_tool composer /usr/local/bin/composer ;;
        wp-cli) _upgrade_single_file_tool wp-cli /usr/local/bin/wp ;;
        phpmyadmin) _upgrade_remove_phpmyadmin ;;
        acme) _upgrade_acme ;;
        *) die_code "$EX_USAGE" "Unknown upgrade component: ${component}" ;;
    esac
}

_upgrade_known_component() {
    local requested="$1" component
    for component in "${UPGRADE_COMPONENTS[@]}"; do
        [[ "$requested" = "$component" ]] && return 0
    done
    return 1
}

upgrade_apply() {
    [[ $# -gt 0 ]] || die_code "$EX_USAGE" "Select at least one component or 'outdated'. Run: lnmp upgrade plan"

    local requested component status selected_words=' '
    local -a selected=()
    for requested in "$@"; do
        if [[ "$requested" = outdated || "$requested" = all ]]; then
            for component in "${UPGRADE_COMPONENTS[@]}"; do
                if [[ "$(_upgrade_component_status "$component")" = OUTDATED && "$selected_words" != *" ${component} "* ]]; then
                    selected+=("$component")
                    selected_words+="${component} "
                fi
            done
        else
            _upgrade_known_component "$requested" \
                || die_code "$EX_USAGE" "Unknown upgrade component: ${requested}"
            if [[ "$selected_words" != *" ${requested} "* ]]; then
                selected+=("$requested")
                selected_words+="${requested} "
            fi
        fi
    done

    [[ ${#selected[@]} -gt 0 ]] || { log_ok "No installed component requires an upgrade."; return 0; }
    for component in "${selected[@]}"; do
        status=$(_upgrade_component_status "$component")
        case "$status" in
            MISSING) die_code "$EX_USAGE" "${component} is not installed; upgrade will not install optional components." ;;
            AHEAD) die_code "$EX_USAGE" "${component} is newer than the pinned target; refusing a downgrade." ;;
        esac
    done

    check_root
    command -v flock >/dev/null 2>&1 \
        || die_code "$EX_UNAVAILABLE" "flock is required to serialize upgrades."
    mkdir -p /run/lock
    exec 9>/run/lock/lnmp-upgrade.lock
    flock -n 9 || die "Another LNMP upgrade is already running."
    _upgrade_load_build_libraries
    for component in "${selected[@]}"; do
        status=$(_upgrade_component_status "$component")
        case "$status" in
            CURRENT)
                log_info "${component} already matches the pinned target; skipping."
                continue
                ;;
            MISSING)
                die_code "$EX_USAGE" "${component} is no longer installed; refusing to add it during upgrade."
                ;;
            AHEAD)
                die_code "$EX_USAGE" "${component} became newer than the pinned target; refusing a downgrade."
                ;;
        esac
        log_info "Applying upgrade: ${component}"
        _upgrade_one "$component" || die "Upgrade failed for ${component}; rollback was attempted."
    done

    log_ok "Selected upgrades completed."
    upgrade_plan
}
