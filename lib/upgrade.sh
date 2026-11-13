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

_upgrade_version_series() {
    local version="${1%%[-+]*}" major minor
    IFS='.' read -r major minor _ <<< "$version"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    printf '%s.%s' "$major" "$minor"
}

_upgrade_requires_explicit_review() {
    local component="$1" installed="$2" target="$3"
    local installed_series target_series
    case "$component" in
        nginx|php|db)
            installed_series=$(_upgrade_version_series "$installed") || return 0
            target_series=$(_upgrade_version_series "$target") || return 0
            [[ "$installed_series" != "$target_series" ]]
            ;;
        redis)
            [[ "${installed%%.*}" =~ ^[0-9]+$ && "${target%%.*}" =~ ^[0-9]+$ ]] \
                || return 0
            [[ "${installed%%.*}" != "${target%%.*}" ]]
            ;;
        *)
            return 1
            ;;
    esac
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

    if [[ "$status" = OUTDATED ]] \
        && _upgrade_requires_explicit_review "$component" "$installed" "$target"; then
        status=REVIEW
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
        [[ "$status" = OUTDATED || "$status" = REVIEW ]] && action="lnmp upgrade apply ${component}"
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
    _upgrade_php_config_summary
}

_upgrade_php_config_summary() {
    [[ -x /usr/local/php/bin/php ]] || return 0
    local extensions unknown ext
    extensions=$(_upgrade_php_dynamic_extensions | paste -sd, -)
    while IFS= read -r ext; do
        [[ -n "$ext" ]] || continue
        _upgrade_php_extension_managed "$ext" || unknown+="${unknown:+,}${ext}"
    done < <(_upgrade_php_dynamic_extensions)
    printf 'PHP configuration: preserve php.ini, php-fpm.conf, php-fpm.d/* and php.d/*; update only project security overlays.\n'
    printf 'PHP dynamic extensions: %s\n' "${extensions:-none}"
    [[ -z "$unknown" ]] \
        || printf 'PHP unmanaged extensions: %s (blocks PHP apply until build metadata is added)\n' "$unknown"
}


_upgrade_load_build_libraries() {
    [[ -n "${_UPGRADE_BUILD_LIBS_LOADED:-}" ]] && return 0
    # shellcheck disable=SC2154  # cur_dir is initialized by lib/common.sh.
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

_upgrade_init_log() {
    local log_dir="${LNMP_UPGRADE_LOG_DIR:-/var/log/lnmp}"
    install -d -m 0700 "$log_dir" || die "Cannot create upgrade log directory: ${log_dir}"
    LOG_FILE="${log_dir}/upgrade-$(date +%Y%m%d%H%M%S)-$$.log"
    install -m 0600 /dev/null "$LOG_FILE" || die "Cannot create upgrade log: ${LOG_FILE}"
    log_info "Upgrade log: ${LOG_FILE}"
}

_upgrade_require_commands() {
    local component command
    local -a required=(wget sha256sum tar diff cmp stat find comm paste readlink)
    local -a missing=()

    for component in "$@"; do
        case "$component" in
            nginx)
                required+=(make gcc patch perl pkg-config)
                ;;
            php)
                required+=(make gcc g++ pkg-config)
                ;;
            redis)
                required+=(make gcc)
                ;;
            memcached)
                required+=(make gcc pkg-config)
                ;;
            ext:*)
                required+=(make gcc autoconf pkg-config)
                ;;
            db)
                required+=(gzip ldd)
                ;;
        esac
    done
    for command in "${required[@]}"; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    [[ ${#missing[@]} -eq 0 ]] || die_code "$EX_UNAVAILABLE" \
        "Upgrade prerequisites are missing: ${missing[*]}. Install the current lnmp-stack build dependencies, then retry. Log: ${LOG_FILE}"
}

_upgrade_validate_nginx_modules() {
    local output configure_args token
    output="${NGINX_BUILD_OUTPUT:-}"
    if [[ -z "$output" ]]; then
        output=$(/usr/local/nginx/sbin/nginx -V 2>&1) \
            || die_code "$EX_UNAVAILABLE" "Cannot inspect the current Nginx build. Log: ${LOG_FILE}"
    fi
    configure_args="${output#*configure arguments: }"
    for token in $configure_args; do
        case "$token" in
            --add-module=*|--add-dynamic-module=*)
                if [[ " ${Nginx_Modules_Options:-} " = *" ${token} "* ]]; then
                    continue
                fi
                if [[ "${Enable_Nginx_Lua:-n}" = y ]] \
                    && [[ "$token" = *lua-nginx-module* || "$token" = *ngx_devel_kit* ]]; then
                    continue
                fi
                die_code "$EX_USAGE" \
                    "Current Nginx uses ${token}, but the option is absent from lnmp.conf.local. Add it to Nginx_Modules_Options before upgrading; no binaries were changed. Log: ${LOG_FILE}"
                ;;
        esac
    done
}

_upgrade_php_dynamic_extensions() {
    local root="${PHP_UPGRADE_CONFIG_ROOT:-/usr/local/php/etc}"
    local file line key value name
    local -a files=()
    [[ -f "${root}/php.ini" ]] && files+=("${root}/php.ini")
    shopt -s nullglob
    files+=("${root}/php.d/"*.ini)
    shopt -u nullglob

    for file in "${files[@]}"; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "$line" = \;* || "$line" = \#* ]] && continue
            [[ "$line" = *=* ]] || continue
            key="${line%%=*}"
            key="${key%"${key##*[![:space:]]}"}"
            [[ "$key" = extension || "$key" = zend_extension ]] || continue
            value="${line#*=}"
            value="${value%%;*}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"
            name="${value##*/}"
            name="${name%%.so*}"
            [[ -n "$name" && "$name" != opcache ]] && printf '%s\n' "$name"
        done < "$file"
    done | LC_ALL=C sort -u
}

_upgrade_php_extension_managed() {
    case "$1" in
        redis|imagick|apcu|swoole|memcached|imap) return 0 ;;
        *) return 1 ;;
    esac
}

_upgrade_validate_php_extensions() {
    local ext unknown=''
    while IFS= read -r ext; do
        [[ -n "$ext" ]] || continue
        _upgrade_php_extension_managed "$ext" || unknown+="${unknown:+, }${ext}"
    done < <(_upgrade_php_dynamic_extensions)
    [[ -z "$unknown" ]] || die_code "$EX_USAGE" \
        "PHP uses unmanaged dynamic extension(s): ${unknown}. Add pinned source/build metadata to lib/extensions.sh before upgrading PHP; no binaries were changed. Log: ${LOG_FILE}"
}

_upgrade_rollback_ok() {
    log_warn "$1 rollback completed; restored backup: $2"
}

_upgrade_rollback_failed() {
    log_err "$1 rollback FAILED; manual recovery is required from: $2"
    log_err "Inspect: ${LOG_FILE}"
}

_upgrade_backup_root() {
    local root
    mkdir -p /var/backups/lnmp || die "Cannot create /var/backups/lnmp."
    root=$(mktemp -d "/var/backups/lnmp/$(date +%Y%m%d%H%M%S)-XXXXXX") \
        || die "Cannot create an upgrade backup directory."
    chmod 0700 "$root" || die "Cannot protect upgrade backup directory: ${root}"
    printf '%s' "$root"
}

_upgrade_backup_config() {
    local source="$1" destination="$2"
    [[ -e "$source" || -L "$source" ]] || return 0
    mkdir -p "$(dirname "$destination")" \
        || die "Cannot create configuration backup directory for ${source}."
    cp -a "$source" "$destination" \
        || die "Cannot back up configuration: ${source}"
}

_upgrade_config_metadata() {
    local root="$1" rel path kind metadata
    if [[ -d "$root" && ! -L "$root" ]]; then
        while IFS= read -r rel; do
            path="${root}/${rel#./}"
            if [[ -L "$path" ]]; then
                printf 'link\t%s\t%s\n' "$rel" "$(readlink "$path")"
            else
                if [[ -d "$path" ]]; then
                    kind='directory'
                else
                    kind='file'
                fi
                metadata=$(_upgrade_file_metadata "$path") || return 1
                printf '%s\t%s\t%s\n' "$kind" "$rel" "$metadata"
            fi
        done < <(cd "$root" && find . -print | LC_ALL=C sort)
        return 0
    fi
    if [[ -L "$root" ]]; then
        printf 'link\t.\t%s\n' "$(readlink "$root")"
    else
        metadata=$(_upgrade_file_metadata "$root") || return 1
        printf 'file\t.\t%s\n' "$metadata"
    fi
}

_upgrade_assert_config_unchanged() {
    local snapshot="$1" live="$2" label="$3" report="$4"
    local content_rc=0 metadata_rc=0
    local metadata_before="${report}.metadata.before"
    local metadata_after="${report}.metadata.after"
    [[ -e "$snapshot" || -L "$snapshot" ]] || return 0
    install -m 0600 /dev/null "$report" \
        || return 1
    install -m 0600 /dev/null "$metadata_before" \
        || return 1
    install -m 0600 /dev/null "$metadata_after" \
        || return 1
    diff -ruN "$snapshot" "$live" > "$report" || content_rc=$?
    _upgrade_config_metadata "$snapshot" > "$metadata_before" \
        || metadata_rc=2
    _upgrade_config_metadata "$live" > "$metadata_after" \
        || metadata_rc=2
    if [[ $metadata_rc -eq 0 ]] && ! cmp -s "$metadata_before" "$metadata_after"; then
        metadata_rc=1
    fi
    if [[ $content_rc -eq 0 && $metadata_rc -eq 0 ]]; then
        printf '# No configuration changes.\n' > "$report"
        chmod 0600 "$report"
        rm -f "$metadata_before" "$metadata_after"
        log_ok "${label} configuration preserved: ${live}; diff: ${report}"
        return 0
    fi
    if [[ $content_rc -gt 1 || $metadata_rc -gt 1 ]]; then
        log_err "Cannot compare ${label} configuration; diff output: ${report}"
    else
        if [[ $metadata_rc -eq 1 ]]; then
            {
                printf '\n# Metadata changes\n'
                diff -u "$metadata_before" "$metadata_after" || true
            } >> "$report"
        fi
        log_err "${label} configuration changed unexpectedly; diff: ${report}"
    fi
    rm -f "$metadata_before" "$metadata_after"
    return 1
}

_upgrade_write_config_diff() {
    local snapshot="$1" live="$2" report="$3" rc=0
    install -m 0600 /dev/null "$report" || return 1
    if diff -ruN "$snapshot" "$live" > "$report"; then
        printf '# No configuration changes.\n' > "$report"
    else
        rc=$?
        [[ $rc -eq 1 ]] || {
            log_err "Cannot generate configuration diff: ${report}"
            return 1
        }
    fi
    chmod 0600 "$report"
    log_info "Configuration diff: ${report}"
}

_upgrade_file_metadata() {
    local path="$1"
    stat -c '%a:%u:%g' "$path" 2>/dev/null \
        || stat -f '%Lp:%u:%g' "$path" 2>/dev/null
}

_upgrade_php_managed_ini_addition() {
    local file="$1" base ext
    base="${file##*/}"
    ext="${base%.ini}"
    _upgrade_php_extension_managed "$ext" || return 1
    [[ "$(cat "$file")" = "extension=${ext}.so" ]]
}

_upgrade_php_configs_preserved() {
    local snapshot="$1" live="$2" old rel current pattern changed=0
    local -a roots=(php.d php-fpm.d)

    for rel in php.ini php-fpm.conf; do
        old="${snapshot}/${rel}"
        current="${live}/${rel}"
        [[ -e "$old" || -e "$current" ]] || continue
        if [[ ! -f "$old" || ! -f "$current" ]] || ! cmp -s "$old" "$current" \
            || [[ "$(_upgrade_file_metadata "$old")" != "$(_upgrade_file_metadata "$current")" ]]; then
            log_err "PHP operator configuration was not preserved: ${current}"
            changed=1
        fi
    done

    for rel in "${roots[@]}"; do
        if [[ "$rel" = php.d ]]; then
            pattern='*.ini'
        else
            pattern='*.conf'
        fi
        if [[ -d "${snapshot}/${rel}" ]]; then
            while IFS= read -r -d '' old; do
                current="${live}/${old#"${snapshot}/"}"
                [[ "$current" = "${live}/php.d/99-lnmp-security.ini" ]] && continue
                if [[ ! -f "$current" ]] || ! cmp -s "$old" "$current" \
                    || [[ "$(_upgrade_file_metadata "$old")" != "$(_upgrade_file_metadata "$current")" ]]; then
                    log_err "PHP operator configuration was not preserved: ${current}"
                    changed=1
                fi
            done < <(find "${snapshot}/${rel}" \( -type f -o -type l \) -name "$pattern" -print0)
        fi
        if [[ -d "${live}/${rel}" ]]; then
            while IFS= read -r -d '' current; do
                old="${snapshot}/${current#"${live}/"}"
                [[ "$current" = "${live}/php.d/99-lnmp-security.ini" || -e "$old" ]] && continue
                if [[ "$rel" = php.d ]] && _upgrade_php_managed_ini_addition "$current"; then
                    continue
                fi
                log_err "Unexpected active PHP configuration was added: ${current}"
                changed=1
            done < <(find "${live}/${rel}" \( -type f -o -type l \) -name "$pattern" -print0)
        fi
    done
    [[ $changed -eq 0 ]]
}

_upgrade_php_modules() {
    local php_bin="${PHP_UPGRADE_BIN:-/usr/local/php/bin/php}"
    "$php_bin" -m 2>/dev/null \
        | sed -e '/^\[.*\]$/d' -e '/^[[:space:]]*$/d' \
        | LC_ALL=C sort -u
}

_upgrade_php_modules_preserved() {
    local before="$1" after="$2" missing
    missing=$(comm -23 "$before" "$after")
    [[ -z "$missing" ]] && return 0
    log_err "PHP modules disappeared after upgrade: $(printf '%s' "$missing" | paste -sd, -)"
    return 1
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

_upgrade_backup_nginx_runtime_libs() {
    local backup_root="$1" path
    local -a paths=()
    mkdir -p "${backup_root}/nginx-runtime-libs"
    shopt -s nullglob
    paths=(/usr/local/lib/libjemalloc.so* /usr/local/lib/libluajit*.so*)
    shopt -u nullglob
    for path in "${paths[@]}"; do
        cp -a "$path" "${backup_root}/nginx-runtime-libs/" \
            || die "Cannot back up Nginx runtime library: ${path}"
    done
}

_upgrade_restore_nginx_runtime_libs() {
    local backup_root="$1"
    [[ -d "${backup_root}/nginx-runtime-libs" ]] || return 0
    rm -f /usr/local/lib/libjemalloc.so* /usr/local/lib/libluajit*.so*
    cp -a "${backup_root}/nginx-runtime-libs/." /usr/local/lib/
    ldconfig
}

_upgrade_nginx() {
    local backup_root backup_bin
    backup_root=$(_upgrade_backup_root)
    backup_bin="${backup_root}/nginx"
    cp -a /usr/local/nginx/sbin/nginx "$backup_bin" \
        || die "Cannot back up the current Nginx binary."
    _upgrade_save_version_state "$backup_root"
    _upgrade_backup_nginx_runtime_libs "$backup_root"
    _upgrade_backup_config /usr/local/nginx/conf "${backup_root}/nginx-conf"
    _upgrade_backup_config /etc/systemd/system/nginx.service "${backup_root}/nginx.service"
    _upgrade_backup_config /etc/systemd/system/nginx.service.d "${backup_root}/nginx.service.d"
    if ! ( install_nginx upgrade ); then
        cp -a "$backup_bin" /usr/local/nginx/sbin/nginx
        _upgrade_restore_version_state "$backup_root"
        _upgrade_restore_nginx_runtime_libs "$backup_root"
        if /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1 \
            && systemctl is-active --quiet nginx; then
            _upgrade_rollback_ok Nginx "$backup_bin"
        else
            _upgrade_rollback_failed Nginx "$backup_bin"
        fi
        return 1
    fi
    if ! _upgrade_assert_config_unchanged "${backup_root}/nginx-conf" /usr/local/nginx/conf \
            Nginx "${backup_root}/nginx-config.diff" \
        || ! _upgrade_assert_config_unchanged "${backup_root}/nginx.service" /etc/systemd/system/nginx.service \
            Nginx-systemd "${backup_root}/nginx-systemd.diff" \
        || ! _upgrade_assert_config_unchanged "${backup_root}/nginx.service.d" /etc/systemd/system/nginx.service.d \
            Nginx-systemd-overrides "${backup_root}/nginx-systemd-overrides.diff" \
        || ! /usr/local/nginx/sbin/nginx -t || ! systemctl restart nginx; then
        log_err "Nginx validation/restart failed; restoring previous binary."
        cp -a "$backup_bin" /usr/local/nginx/sbin/nginx
        _upgrade_restore_version_state "$backup_root"
        _upgrade_restore_nginx_runtime_libs "$backup_root"
        if /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1 \
            && systemctl restart nginx \
            && systemctl is-active --quiet nginx; then
            _upgrade_rollback_ok Nginx "$backup_bin"
        else
            _upgrade_rollback_failed Nginx "$backup_bin"
        fi
        return 1
    fi
    log_ok "Nginx upgrade deployed. Previous binary: ${backup_bin}"
}

_upgrade_php() {
    local backup_root backup_php ext before_modules after_modules
    local -a installed_extensions=()
    backup_root=$(_upgrade_backup_root)
    backup_php="${backup_root}/php"
    before_modules="${backup_root}/php-modules.before"
    after_modules="${backup_root}/php-modules.after"
    cp -a /usr/local/php "$backup_php" \
        || die "Cannot back up the current PHP prefix."
    _upgrade_backup_config /etc/systemd/system/php-fpm.service "${backup_root}/php-fpm.service"
    _upgrade_backup_config /etc/systemd/system/php-fpm.service.d "${backup_root}/php-fpm.service.d"
    _upgrade_save_version_state "$backup_root"
    _upgrade_php_modules > "$before_modules" \
        || die "Cannot inventory PHP modules before upgrade."
    chmod 0600 "$before_modules"

    for ext in redis imagick apcu swoole memcached imap; do
        [[ -n "$(_upgrade_runtime_version "ext:${ext}")" ]] && installed_extensions+=("$ext")
    done

    if ( install_php upgrade && for ext in "${installed_extensions[@]}"; do install_extension "$ext" y; done ); then
        _upgrade_php_modules > "$after_modules" \
            || log_err "Cannot inventory PHP modules after upgrade."
        chmod 0600 "$after_modules" 2>/dev/null || true
        if _upgrade_write_config_diff "${backup_php}/etc" /usr/local/php/etc \
                "${backup_root}/php-config.diff" \
            && _upgrade_php_configs_preserved "${backup_php}/etc" /usr/local/php/etc \
            && _upgrade_assert_config_unchanged "${backup_root}/php-fpm.service" \
                /etc/systemd/system/php-fpm.service PHP-FPM-systemd \
                "${backup_root}/php-fpm-systemd.diff" \
            && _upgrade_assert_config_unchanged "${backup_root}/php-fpm.service.d" \
                /etc/systemd/system/php-fpm.service.d PHP-FPM-systemd-overrides \
                "${backup_root}/php-fpm-systemd-overrides.diff" \
            && [[ -s "$after_modules" ]] \
            && _upgrade_php_modules_preserved "$before_modules" "$after_modules" \
            && /usr/local/php/sbin/php-fpm -t \
            && systemctl start php-fpm \
            && systemctl is-active --quiet php-fpm; then
            log_ok "PHP upgrade deployed. Previous prefix: ${backup_php}; module inventory: ${after_modules}"
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
    if /usr/local/php/sbin/php-fpm -t >/dev/null 2>&1 \
        && systemctl start php-fpm \
        && systemctl is-active --quiet php-fpm; then
        _upgrade_rollback_ok PHP "$backup_php"
    else
        _upgrade_rollback_failed PHP "$backup_php"
    fi
    return 1
}

_upgrade_redis_wait() {
    local i response line key value
    local redis_cli="${REDIS_CLI_BIN:-/usr/local/redis/bin/redis-cli}"
    local config="${REDIS_CONFIG_FILE:-/usr/local/redis/etc/redis.conf}"
    local port=6379 socket=''
    local -a cli_args=()

    if [[ -r "$config" ]]; then
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$line" || "$line" = \#* ]] && continue
            read -r key value _ <<< "$line"
            case "$key" in
                port) port="$value" ;;
                unixsocket) socket="$value" ;;
            esac
        done < "$config"
    fi
    if [[ -n "$socket" ]]; then
        cli_args=(-s "$socket")
    elif [[ "$port" =~ ^[0-9]+$ ]]; then
        cli_args=(-p "$port")
    fi

    for ((i = 0; i < 120; i++)); do
        response=$("$redis_cli" "${cli_args[@]}" ping 2>&1 || true)
        [[ "$response" = PONG || "$response" = NOAUTH* ]] && return 0
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
    _upgrade_backup_config /usr/local/redis/etc "${backup_root}/redis-config"
    _upgrade_backup_config /etc/systemd/system/redis.service "${backup_root}/redis.service"
    _upgrade_backup_config /etc/systemd/system/redis.service.d "${backup_root}/redis.service.d"
    if ( install_redis_server upgrade ) \
        && _upgrade_assert_config_unchanged "${backup_root}/redis-config" /usr/local/redis/etc \
            Redis "${backup_root}/redis-config.diff" \
        && _upgrade_assert_config_unchanged "${backup_root}/redis.service" /etc/systemd/system/redis.service \
            Redis-systemd "${backup_root}/redis-systemd.diff" \
        && _upgrade_assert_config_unchanged "${backup_root}/redis.service.d" /etc/systemd/system/redis.service.d \
            Redis-systemd-overrides "${backup_root}/redis-systemd-overrides.diff" \
        && systemctl restart redis \
        && _upgrade_redis_wait; then
        log_ok "Redis upgrade deployed. Previous binaries: ${backup_bin}"
        return 0
    fi
    log_err "Redis upgrade failed; restoring previous binaries."
    rm -rf /usr/local/redis/bin
    mv "$backup_bin" /usr/local/redis/bin
    _upgrade_restore_version_state "$backup_root"
    if systemctl restart redis && _upgrade_redis_wait; then
        _upgrade_rollback_ok Redis "$backup_bin"
    else
        _upgrade_rollback_failed Redis "$backup_bin"
    fi
    return 1
}

_upgrade_memcached() {
    local backup_root backup_bin
    backup_root=$(_upgrade_backup_root)
    backup_bin="${backup_root}/memcached-bin"
    cp -a /usr/local/memcached/bin "$backup_bin" \
        || die "Cannot back up the current Memcached binaries."
    _upgrade_save_version_state "$backup_root"
    _upgrade_backup_config /etc/systemd/system/memcached.service "${backup_root}/memcached.service"
    _upgrade_backup_config /etc/systemd/system/memcached.service.d "${backup_root}/memcached.service.d"
    if ( install_memcached_server upgrade ) \
        && _upgrade_assert_config_unchanged "${backup_root}/memcached.service" \
            /etc/systemd/system/memcached.service Memcached-systemd \
            "${backup_root}/memcached-systemd.diff" \
        && _upgrade_assert_config_unchanged "${backup_root}/memcached.service.d" \
            /etc/systemd/system/memcached.service.d Memcached-systemd-overrides \
            "${backup_root}/memcached-systemd-overrides.diff" \
        && systemctl restart memcached \
        && systemctl is-active --quiet memcached; then
        log_ok "Memcached upgrade deployed. Previous binaries: ${backup_bin}"
        return 0
    fi
    log_err "Memcached upgrade failed; restoring previous binaries."
    rm -rf /usr/local/memcached/bin
    mv "$backup_bin" /usr/local/memcached/bin
    _upgrade_restore_version_state "$backup_root"
    if systemctl restart memcached && systemctl is-active --quiet memcached; then
        _upgrade_rollback_ok Memcached "$backup_bin"
    else
        _upgrade_rollback_failed Memcached "$backup_bin"
    fi
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
    _upgrade_backup_config /etc/my.cnf "${backup_root}/db-config/my.cnf"
    _upgrade_backup_config /etc/mysql "${backup_root}/db-config/mysql"
    _upgrade_backup_config "/etc/systemd/system/${service}.service" \
        "${backup_root}/db-config/${service}.service"
    _upgrade_backup_config "/etc/systemd/system/${service}.service.d" \
        "${backup_root}/db-config/${service}.service.d"

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
        if systemctl start "$service" && systemctl is-active --quiet "$service"; then
            _upgrade_rollback_ok "$engine" "$logical_dump"
        else
            _upgrade_rollback_failed "$engine" "$logical_dump"
        fi
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
    _upgrade_assert_config_unchanged "${backup_root}/db-config/my.cnf" /etc/my.cnf \
        Database "${backup_root}/db-my.cnf.diff" || failed=1
    _upgrade_assert_config_unchanged "${backup_root}/db-config/mysql" /etc/mysql \
        Database-includes "${backup_root}/db-includes.diff" || failed=1
    _upgrade_assert_config_unchanged "${backup_root}/db-config/${service}.service" \
        "/etc/systemd/system/${service}.service" Database-systemd \
        "${backup_root}/db-systemd.diff" || failed=1
    _upgrade_assert_config_unchanged "${backup_root}/db-config/${service}.service.d" \
        "/etc/systemd/system/${service}.service.d" Database-systemd-overrides \
        "${backup_root}/db-systemd-overrides.diff" || failed=1

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
    ldconfig || true
    admin_bin="${old_prefix}/bin/mysqladmin"
    if systemctl start "$service" && _upgrade_db_wait "$admin_bin"; then
        _upgrade_rollback_ok "$engine" "$logical_dump"
    else
        _upgrade_rollback_failed "$engine" "$logical_dump"
    fi
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

    if ( install_extension "$ext" y ) \
        && _upgrade_assert_config_unchanged "${backup_root}/${ext}.ini" "$ini_file" \
            "PHP extension ${ext}" "${backup_root}/${ext}-config.diff" \
        && /usr/local/php/sbin/php-fpm -t \
        && systemctl restart php-fpm \
        && systemctl is-active --quiet php-fpm; then
        log_ok "PHP extension ${ext} upgrade deployed. Previous module: ${backup_root}/${ext}.so"
        return 0
    fi
    log_err "PHP extension ${ext} upgrade failed; restoring previous module."
    if [[ -f "${backup_root}/${ext}.ini" ]]; then
        cp -a "${backup_root}/${ext}.ini" "$ini_file"
    else
        rm -f "$ini_file"
    fi
    if [[ -f "${backup_root}/${ext}.so" ]]; then
        cp -a "${backup_root}/${ext}.so" "$so_file"
    else
        rm -f "$so_file"
    fi
    _upgrade_restore_version_state "$backup_root"
    if /usr/local/php/bin/php -r "exit(extension_loaded('${ext}') ? 0 : 1);" \
        && /usr/local/php/sbin/php-fpm -t >/dev/null 2>&1 \
        && systemctl restart php-fpm \
        && systemctl is-active --quiet php-fpm; then
        _upgrade_rollback_ok "PHP extension ${ext}" "$backup_root"
    else
        _upgrade_rollback_failed "PHP extension ${ext}" "$backup_root"
    fi
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
    if [[ -x "$path" ]]; then
        _upgrade_rollback_ok "$tool" "${backup_root}/tool"
    else
        _upgrade_rollback_failed "$tool" "${backup_root}/tool"
    fi
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
    if [[ -x /usr/local/acme.sh/acme.sh ]]; then
        _upgrade_rollback_ok acme.sh "${backup_root}/acme.sh"
    else
        _upgrade_rollback_failed acme.sh "${backup_root}/acme.sh"
    fi
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

    [[ ${#selected[@]} -gt 0 ]] || {
        log_ok "No installed component is eligible for automatic upgrade. REVIEW items require explicit selection."
        return 0
    }
    for component in "${selected[@]}"; do
        status=$(_upgrade_component_status "$component")
        case "$status" in
            MISSING) die_code "$EX_USAGE" "${component} is not installed; upgrade will not install optional components." ;;
            AHEAD) die_code "$EX_USAGE" "${component} is newer than the pinned target; refusing a downgrade." ;;
        esac
    done

    if [[ ${#selected[@]} -eq 1 && "${selected[0]}" = nginx ]]; then
        INSTALL_TARGET=nginx
    else
        INSTALL_TARGET=upgrade
    fi

    check_root
    command -v flock >/dev/null 2>&1 \
        || die_code "$EX_UNAVAILABLE" "flock is required to serialize upgrades."
    local lock_file="${LNMP_UPGRADE_LOCK_FILE:-/run/lock/lnmp-upgrade.lock}"
    mkdir -p "$(dirname "$lock_file")"
    exec 9>"$lock_file"
    flock -n 9 || die "Another LNMP upgrade is already running."
    _upgrade_init_log
    _upgrade_require_commands "${selected[@]}"
    _upgrade_load_build_libraries
    for component in "${selected[@]}"; do
        [[ "$component" = nginx ]] && _upgrade_validate_nginx_modules
        [[ "$component" = php ]] && _upgrade_validate_php_extensions
    done
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
        [[ "$status" = REVIEW ]] \
            && log_warn "${component} crosses a release series; explicit selection accepted. Validate application compatibility after deployment."
        log_info "Applying upgrade: ${component}"
        _upgrade_one "$component" \
            || die "Upgrade failed for ${component}; rollback was attempted. Inspect: ${LOG_FILE}"
    done

    log_ok "Selected upgrades completed."
    upgrade_plan
}
