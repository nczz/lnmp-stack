#!/usr/bin/env bash
# lib/deps.sh — System dependencies, timezone, environment preparation

install_deps() {
    log_info "Installing system dependencies..."

    wait_apt_lock

    log_info "Updating package index..."
    apt-get -qq update

    # Core packages that work across 22.04 / 24.04 / 26.04
    local pkgs=(
        build-essential gcc g++ make cmake autoconf automake
        pkg-config libtool bison re2c
        wget curl ca-certificates gnupg lsb-release
        libxml2-dev libsqlite3-dev libcurl4-openssl-dev libpcre2-dev libicu-dev
        libpng-dev libjpeg-dev libwebp-dev libavif-dev
        libfreetype-dev libonig-dev libreadline-dev
        libsodium-dev libzip-dev libssl-dev libgd-dev
        libxslt1-dev libgmp-dev libldap2-dev libbz2-dev
        libkrb5-dev
        libsystemd-dev libevent-dev libmemcached-dev
        zlib1g-dev liblz4-dev libzstd-dev
        libmagickwand-dev libmagickcore-dev
        libpam0g-dev libnuma-dev numactl
        cron logrotate
    )

    # ncurses: 24.04+ renamed libncurses5-dev → libncurses-dev
    if apt-cache show libncurses-dev &>/dev/null 2>&1; then
        pkgs+=( libncurses-dev )
    else
        pkgs+=( libncurses5-dev )
    fi

    # libaio: 24.04 uses libaio1t64 (time_t transition), earlier uses libaio1
    pkgs+=( libaio-dev )
    if apt-cache show libaio1t64 &>/dev/null 2>&1; then
        pkgs+=( libaio1t64 )
    else
        pkgs+=( libaio1 )
    fi

    # IMAP library: may be missing on newer releases. Only require it when the
    # user explicitly enables PHP IMAP.
    if apt-cache show libc-client2007e-dev &>/dev/null 2>&1; then
        [[ "${INSTALL_TARGET:-lnmp}" = 'lnmp' && "${Enable_PHP_Imap:-n}" = 'y' ]] && pkgs+=( libc-client2007e-dev )
    elif [[ "${INSTALL_TARGET:-lnmp}" = 'lnmp' && "${Enable_PHP_Imap:-n}" = 'y' ]]; then
        if [[ "${Auto_Install:-n}" = 'y' ]]; then
            die "PHP IMAP is enabled, but libc-client2007e-dev is unavailable on Ubuntu ${OS_VER}. Set Enable_PHP_Imap='n' to explicitly skip it."
        fi
        echo ""
        read -r -p "PHP IMAP cannot be built on Ubuntu ${OS_VER} because libc-client2007e-dev is unavailable. Skip PHP IMAP? [y/N] " answer
        if [[ "${answer,,}" = 'y' || "${answer,,}" = 'yes' ]]; then
            Enable_PHP_Imap='n'
            log_warn "Skipping PHP IMAP by user confirmation."
        else
            die "PHP IMAP cannot be installed on this Ubuntu release."
        fi
    fi

    # Prefer tmux over screen (screen may be removed in future Ubuntu releases)
    if apt-cache show tmux &>/dev/null 2>&1; then
        pkgs+=( tmux )
    else
        pkgs+=( screen )
    fi

    log_info "Installing system packages (this may take a few minutes)..."
    apt-get install -y --no-install-recommends "${pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"

    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "Failed to install dependencies"
    log_ok "Dependencies installed."
}

setup_timezone() {
    local tz="${Timezone:-UTC}"
    log_info "Setting timezone to ${tz}..."

    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
    echo "$tz" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata 2>/dev/null

    log_ok "Timezone set to ${tz}."
}

setup_system_limits() {
    log_info "Configuring system limits..."

    cat > /etc/security/limits.d/lnmp.conf <<'EOF'
*  soft  nofile  65535
*  hard  nofile  65535
*  soft  nproc   65535
*  hard  nproc   65535
EOF

    # sysctl tuning
    cat > /etc/sysctl.d/99-lnmp.conf <<'EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
fs.file-max = 655350
EOF
    sysctl -p /etc/sysctl.d/99-lnmp.conf 2>/dev/null

    # Verify BBR
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        log_ok "TCP BBR enabled."
    else
        log_warn "BBR not available (kernel may not support it)."
    fi

    log_ok "System limits configured."
}

setup_journald() {
    log_info "Configuring journald log limits..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size-limit.conf <<'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
EOF
    systemctl restart systemd-journald 2>/dev/null
    journalctl --vacuum-size=20M 2>/dev/null
    log_ok "Journald limited to 100M total, 20M per file."
}

setup_hosts() {
    if ! grep -Eqi '^127.0.0.1[[:space:]]+localhost' /etc/hosts; then
        echo "127.0.0.1 localhost.localdomain localhost" >> /etc/hosts
    fi
}

setup_sudoers() {
    # Allow sudo group to run without password
    if ! grep -q '^%sudo.*NOPASSWD' /etc/sudoers 2>/dev/null; then
        sed -i 's/^%sudo.*ALL=(ALL:ALL) ALL/%sudo   ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
        log_ok "sudo NOPASSWD enabled for sudo group."
    fi
}

check_dns() {
    if ! ping -c1 -W5 google.com &>/dev/null; then
        log_warn "DNS resolution failed. Check /etc/resolv.conf"
    fi
}

create_dirs() {
    mkdir -p /home/wwwroot/default
    mkdir -p /home/wwwlogs
    mkdir -p "${cur_dir}/src"
}

install_docker() {
    [[ "${Enable_Docker}" = 'y' ]] || return 0

    if command -v docker &>/dev/null; then
        log_info "Docker already installed, skipping."
        return 0
    fi

    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh -s -- 2>&1 | tee -a "$LOG_FILE"
    systemctl enable docker
    systemctl start docker

    # Docker Compose plugin (included in modern docker)
    if ! docker compose version &>/dev/null; then
        apt-get install -y docker-compose-plugin 2>&1 | tee -a "$LOG_FILE"
    fi

    log_ok "Docker $(docker --version | awk '{print $3}') installed."
}

install_wp_cli() {
    [[ "${Enable_WP_CLI}" = 'y' ]] || return 0

    if [[ -x /usr/local/bin/wp ]]; then
        log_info "WP-CLI already installed, skipping."
        return 0
    fi

    log_info "Installing WP-CLI..."
    rm -f /usr/local/bin/wp
    curl -sS -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp

    if /usr/local/bin/wp --info &>/dev/null; then
        log_ok "WP-CLI installed."
    else
        log_warn "WP-CLI installed but may need PHP in PATH to work."
    fi
}

# Main entry
prepare_system() {
    setup_hosts
    setup_sudoers
    check_dns
    create_dirs
    install_deps
    setup_timezone
    setup_system_limits
    setup_journald
    setup_swap
    install_docker
}
