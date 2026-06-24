#!/usr/bin/env bash
# lib/mysql.sh — MySQL/MariaDB binary or compile install

install_mysql() {
    _check_db_arch_support
    _check_db_os_support

    if [[ "${DB_Type}" = 'mariadb' ]]; then
        _install_mariadb
    else
        _install_mysql
    fi
}

_check_db_arch_support() {
    [[ "${ARCH}" = "x86_64" ]] && return 0

    die "Database binary install is currently supported only on x86_64. Detected ${ARCH}; use x86_64 Ubuntu Server for lnmp/db targets, or run the nginx target only."
}

_check_db_os_support() {
    local ver_num="${OS_VER/./}"
    [[ "${DB_Type}" = 'mysql' && "$ver_num" -ge 2604 ]] || return 0

    local msg="MySQL ${MYSQL_VER} official binary client tools require libncurses.so.5/libtinfo.so.5, which Ubuntu ${OS_VER} does not provide. Use DB_Type='mariadb' on Ubuntu 26.04, or run MySQL on an older supported Ubuntu release."
    if [[ "${Auto_Install:-n}" = 'y' ]]; then
        die "$msg"
    fi

    log_warn "$msg"
    read -r -p "Switch DB_Type to 'mariadb' for this installation? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES)
            DB_Type='mariadb'
            log_info "Using MariaDB ${MARIADB_VER} for this installation."
            ;;
        *)
            die "MySQL on Ubuntu ${OS_VER} was not approved; aborting before installing an incompatible database binary."
            ;;
    esac
}

# Fix shared library issues for MySQL binary package on Ubuntu 24.04+
_fix_mysql_libs() {
    log_info "Checking MySQL shared library dependencies..."
    wait_apt_lock

    # Detect lib directory based on architecture
    local libdir="/usr/lib/x86_64-linux-gnu"
    [[ "$ARCH" = "aarch64" ]] && libdir="/usr/lib/aarch64-linux-gnu"

    # Install available runtime libs (package names vary by Ubuntu version)
    local lib_pkgs=( libncurses6 libtinfo6 libmecab2 )
    if apt-cache show libaio1t64 &>/dev/null 2>&1; then
        lib_pkgs+=( libaio1t64 )
    elif apt-cache show libaio1 &>/dev/null 2>&1; then
        lib_pkgs+=( libaio1 )
    fi
    apt-get install -y "${lib_pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Failed to install MySQL runtime libraries"

    # MySQL 8.4 binary expects libaio.so.1 — create symlink if only t64 variant exists
    if [[ ! -e "${libdir}/libaio.so.1" ]]; then
        if [[ -e "${libdir}/libaio.so.1t64" ]]; then
            ln -sf "${libdir}/libaio.so.1t64" "${libdir}/libaio.so.1"
            log_info "Symlinked libaio.so.1t64 → libaio.so.1"
        fi
    fi

    ldconfig
}

# Verify MySQL binary can find all shared libraries
_verify_mysql_libs() {
    local bin="$1"
    local missing
    missing=$(ldd "$bin" 2>&1 | grep 'not found' || true)
    if [[ -n "$missing" ]]; then
        log_err "Missing shared libraries for ${bin}:"
        echo "$missing" | tee -a "$LOG_FILE"
        die "Fix library dependencies before continuing. Do not satisfy missing libncurses.so.5/libtinfo.so.5 by symlinking v6 libraries; use a compatible database binary or package instead."
    fi
    log_ok "Shared library check passed for $(basename "$bin")"
}

_install_mysql() {
    log_info "=== Installing MySQL ${MYSQL_VER} (binary) ==="

    local db_dir="${MySQL_Data_Dir:-/usr/local/mysql/var}"

    id -u mysql &>/dev/null || useradd -s /sbin/nologin -M mysql

    # Ensure required shared libraries
    _fix_mysql_libs

    download_src "MySQL" "$MYSQL_URL"

    cd /usr/local/
    local tarball="$(basename "$MYSQL_URL")"
    tar Jxf "${cur_dir}/src/${tarball}"

    # MySQL binary tarball extracts to mysql-VERSION-linux-glibcX.XX-ARCH
    local extracted_dir
    extracted_dir="$(ls -d mysql-${MYSQL_VER}-linux-glibc* 2>/dev/null | head -1)"
    [[ -n "$extracted_dir" ]] || die "Cannot find extracted MySQL directory"
    mv "$extracted_dir" mysql

    mkdir -p "$db_dir"
    chown -R mysql:mysql /usr/local/mysql
    chown -R mysql:mysql "$db_dir"

    # Verify shared libraries before proceeding
    _verify_mysql_libs /usr/local/mysql/bin/mysqld
    _verify_mysql_libs /usr/local/mysql/bin/mysql
    _verify_mysql_libs /usr/local/mysql/bin/mysqladmin

    # Generate my.cnf from template
    _deploy_mysql_conf "$db_dir"

    # Initialize
    /usr/local/mysql/bin/mysqld --initialize-insecure --user=mysql \
        --basedir=/usr/local/mysql --datadir="$db_dir" 2>&1 | tee -a "$LOG_FILE"

    # Install systemd unit
    cp "${cur_dir}/systemd/mysql.service" /etc/systemd/system/mysql.service
    systemctl daemon-reload
    systemctl enable mysql
    systemctl start mysql

    # Wait for startup
    local i
    for i in $(seq 1 60); do
        /usr/local/mysql/bin/mysqladmin -u root ping &>/dev/null && break
        sleep 2
    done

    # Secure installation
    _secure_mysql "$db_dir"

    # Load timezone tables so named timezones (e.g. Asia/Taipei) work in queries
    _load_mysql_tz

    # Symlinks
    ln -sf /usr/local/mysql/bin/mysql /usr/bin/mysql
    ln -sf /usr/local/mysql/bin/mysqldump /usr/bin/mysqldump
    ln -sf /usr/local/mysql/bin/mysqladmin /usr/bin/mysqladmin

    # Add to library path
    echo "/usr/local/mysql/lib" > /etc/ld.so.conf.d/mysql.conf
    ldconfig

    log_ok "MySQL ${MYSQL_VER} installed."
}

_install_mariadb() {
    log_info "=== Installing MariaDB ${MARIADB_VER} (binary) ==="

    local db_dir="${MariaDB_Data_Dir:-/usr/local/mariadb/var}"

    id -u mysql &>/dev/null || useradd -s /sbin/nologin -M mysql

    download_src "MariaDB" "$MARIADB_URL"

    cd /usr/local/
    local tarball="$(basename "$MARIADB_URL")"
    tar zxf "${cur_dir}/src/${tarball}"

    # MariaDB binary tarball extracts to mariadb-VERSION-linux-systemd-ARCH
    local extracted_dir
    extracted_dir="$(ls -d mariadb-${MARIADB_VER}-linux-* 2>/dev/null | head -1)"
    [[ -n "$extracted_dir" ]] || die "Cannot find extracted MariaDB directory"
    mv "$extracted_dir" mariadb
    ln -sf /usr/local/mariadb /usr/local/mysql

    mkdir -p "$db_dir"
    chown -R mysql:mysql /usr/local/mariadb
    chown -R mysql:mysql "$db_dir"

    _deploy_mysql_conf "$db_dir"

    /usr/local/mariadb/scripts/mariadb-install-db --user=mysql \
        --basedir=/usr/local/mariadb --datadir="$db_dir" 2>&1 | tee -a "$LOG_FILE" \
    || /usr/local/mariadb/scripts/mysql_install_db --user=mysql \
        --basedir=/usr/local/mariadb --datadir="$db_dir" 2>&1 | tee -a "$LOG_FILE"

    sed -e "s|/usr/local/mysql|/usr/local/mariadb|g" \
        -e "s|mysqld|mariadbd|g" \
        "${cur_dir}/systemd/mysql.service" > /etc/systemd/system/mariadb.service
    systemctl daemon-reload
    systemctl enable mariadb
    systemctl start mariadb

    local i
    for i in $(seq 1 60); do
        /usr/local/mariadb/bin/mysqladmin -u root ping &>/dev/null && break
        sleep 2
    done

    _secure_mysql "$db_dir"

    ln -sf /usr/local/mariadb/bin/mysql /usr/bin/mysql
    ln -sf /usr/local/mariadb/bin/mysqldump /usr/bin/mysqldump
    ln -sf /usr/local/mariadb/bin/mysqladmin /usr/bin/mysqladmin

    echo "/usr/local/mariadb/lib" > /etc/ld.so.conf.d/mariadb.conf
    ldconfig

    log_ok "MariaDB ${MARIADB_VER} installed."
}

_deploy_mysql_conf() {
    local db_dir="$1"
    local tz="${Timezone:-UTC}"

    # MySQL requires UTC offset format for default-time-zone before timezone tables are loaded
    # Convert named timezone to offset using system date command
    local tz_offset
    tz_offset=$(TZ="$tz" date +%:z 2>/dev/null || echo "+00:00")

    sed -e "s|{{DATA_DIR}}|${db_dir}|g" \
        -e "s|{{INNODB_BUFFER_POOL}}|${MYSQL_INNODB_BUFFER_POOL}M|g" \
        -e "s|{{MAX_CONNECTIONS}}|${MYSQL_MAX_CONNECTIONS}|g" \
        -e "s|{{TIMEZONE}}|${tz_offset}|g" \
        "${cur_dir}/conf/mysql/my.cnf" > /etc/my.cnf

    log_info "MySQL config deployed (buffer_pool=${MYSQL_INNODB_BUFFER_POOL}M, max_conn=${MYSQL_MAX_CONNECTIONS}, tz=${tz_offset})"
}

_load_mysql_tz() {
    local mysql_bin
    if [[ "${DB_Type}" = 'mariadb' ]]; then
        mysql_bin=/usr/local/mariadb/bin/mysql
        /usr/local/mariadb/bin/mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | ${mysql_bin} -u root mysql 2>/dev/null
    else
        mysql_bin=/usr/local/mysql/bin/mysql
        /usr/local/mysql/bin/mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | ${mysql_bin} -u root mysql 2>/dev/null
    fi
    log_info "MySQL timezone tables loaded."
}

_secure_mysql() {
    local db_dir="$1"
    local mysql_bin

    if [[ "${DB_Type}" = 'mariadb' ]]; then
        mysql_bin=/usr/local/mariadb/bin/mysql
    else
        mysql_bin=/usr/local/mysql/bin/mysql
    fi

    # Generate or use configured root password
    if [[ -n "${MySQL_Root_Password:-}" && "${MySQL_Root_Password}" != 'your_secure_password_here' ]]; then
        DB_Root_Password="${MySQL_Root_Password}"
    else
        DB_Root_Password="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)"
        # Persist generated password to lnmp.conf.local
        local local_conf="${cur_dir}/lnmp.conf.local"
        if [[ -f "$local_conf" ]]; then
            if grep -q '^MySQL_Root_Password=' "$local_conf"; then
                sed -i "s|^MySQL_Root_Password=.*|MySQL_Root_Password='${DB_Root_Password}'|" "$local_conf"
            else
                echo "MySQL_Root_Password='${DB_Root_Password}'" >> "$local_conf"
            fi
        else
            echo "MySQL_Root_Password='${DB_Root_Password}'" > "$local_conf"
        fi
        log_info "Generated random MySQL root password → saved to lnmp.conf.local"
    fi

    ${mysql_bin} -u root <<-EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_Root_Password}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL

    # Save password to protected file
    cat > /root/.my.cnf <<-EOF
[client]
user=root
password=${DB_Root_Password}
EOF
    chmod 600 /root/.my.cnf

    log_ok "MySQL secured. Root password saved to /root/.my.cnf"
}
