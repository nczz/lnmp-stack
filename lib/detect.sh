#!/usr/bin/env bash
# lib/detect.sh — Ubuntu version detection + hardware spec detection

detect_os() {
    [[ -f /etc/os-release ]] || die "Cannot detect OS: /etc/os-release not found"
    . /etc/os-release

    OS_ID="$ID"
    OS_VER="$VERSION_ID"
    OS_CODENAME="$VERSION_CODENAME"
    ARCH="$(uname -m)"

    [[ "$OS_ID" = "ubuntu" ]] || die "Only Ubuntu is supported. Detected: ${OS_ID}"
    [[ "$ARCH" = "x86_64" || "$ARCH" = "aarch64" ]] || die "Unsupported architecture: ${ARCH}"
    if [[ "$ARCH" != "x86_64" && "${INSTALL_TARGET:-}" != "nginx" ]]; then
        die "The ${INSTALL_TARGET:-lnmp} target requires x86_64 because MySQL/MariaDB are installed from official x86_64 binary tarballs. Detected: ${ARCH}"
    fi

    log_info "OS: Ubuntu ${OS_VER} (${OS_CODENAME}) ${ARCH}"
}

check_os_support() {
    local ver_num="${OS_VER/./}"
    if [[ "$ver_num" -lt 2204 ]]; then
        die "Ubuntu ${OS_VER} is not supported. Minimum: 22.04 LTS"
    fi

    # Warn on non-LTS releases (odd .10 releases like 24.10, 25.04, 25.10)
    case "$OS_VER" in
        22.04|24.04|26.04) ;;  # known LTS versions
        *)
            log_warn "Ubuntu ${OS_VER} is not a LTS release. This stack is tested on LTS only."
            log_warn "Supported LTS versions: 26.04 (recommended), 24.04, 22.04"
            ;;
    esac

    if [[ "$ver_num" -ge 2604 ]]; then
        log_ok "Ubuntu ${OS_VER} (${OS_CODENAME}) — recommended target."
    else
        log_ok "Ubuntu ${OS_VER} is supported."
    fi
}

detect_hardware() {
    CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    RAM_GB=$(( (RAM_MB + 512) / 1024 ))  # rounded
    DISK_AVAIL_GB=$(df -BG / | awk 'NR==2{gsub(/G/,"",$4); print $4}')
    SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')

    log_info "Hardware: ${CPU_CORES} CPU cores, ${RAM_MB}MB RAM (${RAM_GB}GB), ${DISK_AVAIL_GB}GB disk available, ${SWAP_MB}MB swap"

    if [[ "$RAM_MB" -lt 512 ]]; then
        log_warn "RAM < 512MB — MySQL compile install will not be available, binary only."
    fi
    if [[ "$DISK_AVAIL_GB" -lt 5 ]]; then
        die "Insufficient disk space. At least 5GB required, got ${DISK_AVAIL_GB}GB."
    fi
}

# Auto-calculate tuning parameters based on hardware
calc_tuning_params() {
    # Nginx
    NGINX_WORKER_PROCESSES="${CPU_CORES}"
    NGINX_WORKER_CONNECTIONS=$(( CPU_CORES * 1024 ))
    [[ $NGINX_WORKER_CONNECTIONS -gt 65535 ]] && NGINX_WORKER_CONNECTIONS=65535

    # Nginx open_file_cache — scale with RAM
    if [[ $RAM_MB -le 512 ]]; then
        NGINX_OPEN_FILE_CACHE_MAX=50000
    elif [[ $RAM_MB -le 1024 ]]; then
        NGINX_OPEN_FILE_CACHE_MAX=100000
    elif [[ $RAM_MB -le 4096 ]]; then
        NGINX_OPEN_FILE_CACHE_MAX=300000
    else
        NGINX_OPEN_FILE_CACHE_MAX=900000
    fi

    # MySQL InnoDB buffer pool — 50% of RAM (min 128M)
    MYSQL_INNODB_BUFFER_POOL=$(( RAM_MB * 50 / 100 ))
    [[ $MYSQL_INNODB_BUFFER_POOL -lt 128 ]] && MYSQL_INNODB_BUFFER_POOL=128

    # MySQL max connections
    if [[ $RAM_MB -le 512 ]]; then
        MYSQL_MAX_CONNECTIONS=64
    elif [[ $RAM_MB -le 1024 ]]; then
        MYSQL_MAX_CONNECTIONS=128
    elif [[ $RAM_MB -le 4096 ]]; then
        MYSQL_MAX_CONNECTIONS=256
    else
        MYSQL_MAX_CONNECTIONS=512
    fi

    # PHP-FPM children — based on RAM (each child ~30-50MB)
    local php_mem=$(( RAM_MB * 30 / 100 ))  # 30% of RAM for PHP
    PHP_FPM_MAX_CHILDREN=$(( php_mem / 40 ))
    [[ $PHP_FPM_MAX_CHILDREN -lt 4 ]] && PHP_FPM_MAX_CHILDREN=4
    [[ $PHP_FPM_MAX_CHILDREN -gt 512 ]] && PHP_FPM_MAX_CHILDREN=512
    PHP_FPM_START_SERVERS=$(( PHP_FPM_MAX_CHILDREN / 4 ))
    [[ $PHP_FPM_START_SERVERS -lt 2 ]] && PHP_FPM_START_SERVERS=2
    PHP_FPM_MIN_SPARE=$(( PHP_FPM_START_SERVERS ))
    PHP_FPM_MAX_SPARE=$(( PHP_FPM_MAX_CHILDREN / 2 ))

    # PHP memory_limit
    if [[ $RAM_MB -le 512 ]]; then
        PHP_MEMORY_LIMIT='64M'
    elif [[ $RAM_MB -le 1024 ]]; then
        PHP_MEMORY_LIMIT='128M'
    elif [[ $RAM_MB -le 4096 ]]; then
        PHP_MEMORY_LIMIT='256M'
    else
        PHP_MEMORY_LIMIT='512M'
    fi

    log_info "Tuning: Nginx workers=${NGINX_WORKER_PROCESSES}, MySQL buffer_pool=${MYSQL_INNODB_BUFFER_POOL}M, PHP-FPM max_children=${PHP_FPM_MAX_CHILDREN}"
}

# Pre-flight: detect /usr/local libraries that conflict with apt-installed -dev packages
check_env_conflicts() {
    # library name | /usr/local file to check | apt package it conflicts with
    local conflicts=(
        "iconv|include/iconv.h|libc6-dev"
        "libiconv|lib/libiconv.so|libc6-dev"
        "libssl|lib/libssl.so|libssl-dev"
        "libxml2|include/libxml2/libxml/parser.h|libxml2-dev"
        "libcurl|lib/libcurl.so|libcurl4-openssl-dev"
        "libpng|lib/libpng.so|libpng-dev"
        "libjpeg|lib/libjpeg.so|libjpeg-dev"
        "libfreetype|lib/libfreetype.so|libfreetype-dev"
        "libonig|lib/libonig.so|libonig-dev"
        "libzip|lib/libzip.so|libzip-dev"
        "libpcre2|lib/libpcre2-8.so|libpcre2-dev"
        "libgd|lib/libgd.so|libgd-dev"
    )

    local found=()
    for entry in "${conflicts[@]}"; do
        IFS='|' read -r name localfile aptpkg <<< "$entry"
        [[ -e "/usr/local/${localfile}" ]] || continue
        dpkg -s "$aptpkg" &>/dev/null || continue
        found+=("  /usr/local/${localfile}  (conflicts with apt: ${aptpkg})")
    done

    [[ ${#found[@]} -eq 0 ]] && { log_ok "No /usr/local library conflicts detected."; return 0; }

    log_warn "Detected /usr/local libraries that may conflict with system packages:"
    for line in "${found[@]}"; do
        log_warn "$line"
    done

    local backup_dir="/tmp/lnmp-env-backup-$(date +%Y%m%d%H%M%S)"

    if [[ "${Auto_Install}" = 'y' ]]; then
        log_info "Auto mode: backing up and removing conflicting files..."
    else
        echo ""
        read -r -p "Back up conflicting files to ${backup_dir} and remove? [Y/n] " answer
        [[ "${answer,,}" = 'n' ]] && { log_warn "Skipped — compilation may fail."; return 0; }
    fi

    mkdir -p "$backup_dir"
    for entry in "${conflicts[@]}"; do
        IFS='|' read -r name localfile aptpkg <<< "$entry"
        [[ -e "/usr/local/${localfile}" ]] || continue
        dpkg -s "$aptpkg" &>/dev/null || continue

        # Back up and remove all related files for this library
        local dir base
        dir="$(dirname "/usr/local/${localfile}")"
        base="$(basename "/usr/local/${localfile}" | sed 's/\.so$//' | sed 's/\.h$//')"
        mkdir -p "${backup_dir}/${dir#/usr/local/}"
        for f in "${dir}/${base}"* ; do
            [[ -e "$f" ]] || continue
            cp -a "$f" "${backup_dir}/${dir#/usr/local/}/"
            rm -f "$f"
        done
        # Also remove .la and .a variants in lib/
        if [[ "$localfile" == lib/* ]]; then
            for f in "/usr/local/lib/${base}"*.{la,a} ; do
                [[ -e "$f" ]] || continue
                cp -a "$f" "${backup_dir}/lib/"
                rm -f "$f"
            done
        fi
    done

    log_ok "Conflicting files backed up to ${backup_dir} and removed."
    ldconfig 2>/dev/null || true
}

# Setup swap if needed
setup_swap() {
    [[ "${Enable_Swap}" = 'y' ]] || return 0
    [[ $SWAP_MB -gt 0 ]] && return 0
    [[ $RAM_MB -ge 2048 ]] && return 0

    local swap_size
    if [[ $RAM_MB -le 512 ]]; then
        swap_size=1024
    else
        swap_size=${RAM_MB}
    fi

    log_info "Creating ${swap_size}MB swap file..."
    dd if=/dev/zero of=/var/swap bs=1M count=${swap_size} 2>/dev/null
    chmod 600 /var/swap
    mkswap /var/swap
    swapon /var/swap
    if ! grep -q '/var/swap' /etc/fstab; then
        echo '/var/swap swap swap defaults 0 0' >> /etc/fstab
    fi
    log_ok "Swap ${swap_size}MB created."
}
