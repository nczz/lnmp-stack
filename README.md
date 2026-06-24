# LNMP Stack

Automated LNMP (Linux + Nginx + MySQL/MariaDB + PHP) environment builder for Ubuntu servers.

All software compiled from source or installed via official binaries — no third-party mirrors, no vendor lock-in.

## Features

- **Ubuntu-only** — Supports Ubuntu 26.04 LTS (recommended), 24.04 LTS, and 22.04 LTS
- **Compile from source** — Nginx with latest OpenSSL (HTTP/2, HTTP/3, TLS 1.3), PHP 8.4 with OPcache JIT
- **Auto-tuning** — Nginx workers, file cache, MySQL InnoDB buffer pool, PHP-FPM children automatically calculated based on host CPU/RAM
- **System hardening** — TCP BBR, sysctl tuning, journald log limits, swap auto-creation
- **Timezone unified** — Single `Timezone` setting applied across system, PHP, and MySQL
- **IP protection** — Auto-generated catch-all server block prevents SSL certificate leakage via IP access
- **PHP extension framework** — Registry-based PECL extension compilation
- **Batch extension install** — Pre-configure extensions in config, built automatically during installation
- **Tools included** — Composer, WP-CLI, phpMyAdmin installed by default; Docker can be enabled in config
- **SSL management** — Let's Encrypt via acme.sh, self-signed certs, expiry monitoring
- **Security hardening** — SSH hardening, optional fail2ban/firewall, per-vhost open_basedir
- **systemd native** — All services managed via systemd with auto-restart on failure
- **100% official sources** — Every download comes from nginx.org, php.net, cdn.mysql.com, etc.
- **Non-interactive mode** — `--auto` flag for fully automated deployment (cloud-init / Terraform ready)

## Supported OS

| OS | Version | Status |
|----|---------|--------|
| Ubuntu | 26.04 LTS (Resolute) | ✅ Recommended |
| Ubuntu | 24.04 LTS (Noble) | ✅ Supported |
| Ubuntu | 22.04 LTS (Jammy) | ✅ Supported |

Full `lnmp` and `db` installs currently require `x86_64` / amd64 because the
database engines are installed from official x86_64 binary tarballs. The
`nginx` target can run on `aarch64`, but database installation will stop with a
clear error instead of installing an incompatible binary.

## Software Stack

| Software | Version | Install Method |
|----------|---------|----------------|
| Nginx | 1.30.3 | Compile (with OpenSSL 3.5.7) |
| MariaDB | 11.4.5 LTS | Binary (default) |
| MySQL | 8.4.9 LTS | Binary (not supported on Ubuntu 26.04) |
| PHP | 8.4.22 | Compile |
| Redis | 7.4.2 | Compile (optional) |
| Docker | Latest | Official script (get.docker.com) |
| Composer | Latest | Official installer (getcomposer.org) |
| WP-CLI | Latest | Official phar (wp-cli.org) |
| phpMyAdmin | 5.2.2 | Official tarball |

## Quick Start

```bash
git clone https://github.com/nczz/lnmp-stack.git
cd lnmp-stack

# Create your local config (overrides lnmp.conf defaults)
cat > lnmp.conf.local << 'EOF'
Timezone='Asia/Taipei'
MySQL_Root_Password='your_secure_password'
PHP_Extensions_Install='redis imagick apcu'
EOF

# Install full stack
sudo ./install.sh lnmp

# Or non-interactive (cloud-init / Terraform ready)
sudo ./install.sh --auto lnmp
```

> **Note:** Do not edit `lnmp.conf` directly — it will be overwritten by `git pull`.
> Always use `lnmp.conf.local` for your customizations. It is gitignored and persists across updates.

## Configuration

All settings are documented with comments in `lnmp.conf`. Create `lnmp.conf.local` to override any value.

Load order: `versions.conf` → `lnmp.conf` (defaults) → `lnmp.conf.local` (your overrides)

### Database

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DB_Type` | `mariadb` | Database engine: `mariadb` or `mysql` |
| `MySQL_Data_Dir` | `/usr/local/mysql/var` | MySQL data directory |
| `MariaDB_Data_Dir` | `/usr/local/mariadb/var` | MariaDB data directory |
| `MySQL_Root_Password` | (auto-generated) | Root password. If not set, a random one is generated and saved to `.local` |

On Ubuntu 26.04, `DB_Type='mysql'` is blocked by default because Oracle's
official MySQL 8.4 binary client tools still require `libncurses.so.5` and
`libtinfo.so.5`, which are not available from Ubuntu 26.04 repositories. Use
the default `DB_Type='mariadb'` for Ubuntu 26.04. MySQL remains available for
older supported Ubuntu releases where its binary dependencies can be satisfied.

### Nginx

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Nginx_Modules_Options` | (empty) | Extra compile options, e.g. `--add-module=/path` |
| `Enable_Nginx_Openssl` | `y` | Compile with latest OpenSSL (HTTP/2, HTTP/3, TLS 1.3) |
| `Enable_Nginx_Lua` | `n` | Compile with Lua module (for WAF, custom logic) |
| `Memory_Allocator` | `jemalloc` | Memory allocator: `jemalloc` or `none` |

### PHP

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PHP_Modules_Options` | (empty) | Extra compile options, e.g. `--with-pgsql` |
| `Enable_PHP_Exif` | `n` | Image EXIF metadata reading |
| `Enable_PHP_Fileinfo` | `n` | File MIME type detection |
| `Enable_PHP_Ldap` | `n` | LDAP directory access |
| `Enable_PHP_Bz2` | `n` | Bzip2 compression |
| `Enable_PHP_Sodium` | `n` | Modern cryptography (libsodium) |
| `Enable_PHP_Imap` | `n` | IMAP email protocol |
| `PHP_Extensions_Install` | `redis imagick apcu` | PECL extensions to compile after install |

On Ubuntu releases where `libc-client2007e-dev` is unavailable, PHP IMAP cannot
be built. If `Enable_PHP_Imap='y'`, the installer asks whether to skip IMAP in
interactive mode; in `--auto` mode it stops and requires you to set
`Enable_PHP_Imap='n'` explicitly.

### Tools

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Enable_Composer` | `y` | PHP dependency manager |
| `Enable_Docker` | `n` | Docker + Docker Compose |
| `Enable_WP_CLI` | `y` | WordPress command-line tool |
| `Enable_phpMyAdmin` | `y` | phpMyAdmin in default host (http://IP/phpmyadmin/) |

### System

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Timezone` | `Asia/Taipei` | Applied to system, PHP, and MySQL |
| `Default_Website_Dir` | `/home/wwwroot/default` | Default website root |
| `Enable_Swap` | `y` | Auto-create swap when RAM < 2GB |
| `Auto_Install` | `n` | Skip prompts (set automatically by `--auto` flag) |

### Security

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Enable_Fail2ban` | `n` | SSH + Nginx brute-force protection |
| `Firewall` | `n` | `ufw`, `iptables`, or `n` (disabled) |

## Auto-Tuning

Configs are automatically optimized based on server specs:

| Parameter | Formula |
|-----------|---------|
| Nginx `worker_processes` | = CPU cores |
| Nginx `worker_connections` | = CPU cores × 1024 (max 65535) |
| Nginx `open_file_cache max` | 50K ~ 900K based on RAM |
| MySQL `innodb_buffer_pool_size` | = 50% of RAM (min 128M) |
| MySQL `max_connections` | 64 ~ 512 based on RAM |
| PHP-FPM `pm.max_children` | = 30% of RAM ÷ 40MB per child |
| PHP `memory_limit` | 64M ~ 512M based on RAM |

## System Initialization

The installer automatically configures the host environment:

- **TCP BBR** — Enables BBR congestion control
- **sysctl tuning** — TCP fastopen, keepalive, port range, file limits, swappiness
- **journald limits** — 100M total, 20M per file to prevent log bloat
- **ulimit** — nofile/nproc set to 65535
- **Swap** — Auto-created when RAM < 2GB
- **sudo NOPASSWD** — Enabled for sudo group
- **Timezone** — System, PHP, and MySQL all set from single config value

## Install Modes

```bash
sudo ./install.sh lnmp          # Full stack: Nginx + MySQL + PHP
sudo ./install.sh nginx         # Nginx only
sudo ./install.sh db            # Database only
sudo ./install.sh --auto lnmp   # Non-interactive
```

## Service Management

Bash completion is installed automatically — press `Tab` to autocomplete commands and options.

```bash
lnmp start                # Start all services
lnmp stop                 # Stop all services
lnmp restart              # Restart all services
lnmp reload               # Reload Nginx + PHP-FPM configs
lnmp status               # Show service status with versions
lnmp kill                 # Force kill all LNMP processes
```

## Virtual Host Management

```bash
# CLI mode (non-interactive)
lnmp vhost add example.com --rewrite wordpress --ssl --redirect
lnmp vhost add example.com --domains "www.example.com" --rewrite laravel --ssl
lnmp vhost del example.com
lnmp vhost list

# Interactive mode
lnmp vhost add
```

Options: `--domains`, `--webroot`, `--rewrite`, `--ssl`, `--redirect`

## SSL Certificate Management

```bash
lnmp ssl install example.com          # Issue Let's Encrypt certificate
lnmp ssl renew                        # Renew all certificates
lnmp ssl renew example.com            # Renew specific domain
lnmp ssl revoke                       # Revoke and remove certificate
lnmp ssl list                         # List certs with expiry (✅/⚠️/🔴)
lnmp ssl self                         # Generate self-signed certificate
```

- Uses Let's Encrypt as default CA (not ZeroSSL)
- EC-256 key type by default
- DH parameters auto-generated during install
- HTTPS catch-all with `ssl_reject_handshake` prevents cert leakage via IP

## Database Management

```bash
# CLI mode
lnmp db add mysite myuser 'mypass'    # Create database + user
lnmp db del mysite                    # Drop database + user
lnmp db list                          # List databases and users
lnmp db export mysite                 # Export to .sql.gz
lnmp db import mysite backup.sql.gz   # Import (supports .gz)

# Interactive mode
lnmp db add

# Reset MySQL root password (reads from lnmp.conf.local)
lnmp reset-password
```

## PHP Extensions

```bash
# Pre-install via config
PHP_Extensions_Install='redis imagick apcu swoole'

# Or manage later
sudo ./tools/addons.sh install redis
sudo ./tools/addons.sh install imagick
sudo ./tools/addons.sh uninstall swoole
sudo ./tools/addons.sh list

# Available: redis, imagick, apcu, swoole, memcached, sodium

# Standalone services
sudo ./tools/addons.sh install redis-server
sudo ./tools/addons.sh install memcached-server
```

OPcache with JIT is a PHP built-in module, always compiled and enabled.

## Additional Tools

```bash
sudo ./tools/upgrade.sh nginx      # Upgrade Nginx (edit versions.conf first)
sudo ./tools/upgrade.sh php        # Upgrade PHP
sudo ./tools/backup.sh [dir]       # Backup DB + sites + configs (7-day retention)
sudo ./tools/uninstall.sh          # Uninstall (backup DB + preserve sites)
sudo ./tools/uninstall.sh --reset  # Full reset for clean reinstall
```

## Directory Layout

| Path | Description |
|------|-------------|
| `/usr/local/nginx/` | Nginx installation |
| `/usr/local/nginx/conf/vhost/` | Virtual host configs |
| `/usr/local/nginx/conf/ssl/` | SSL certificates + DH parameters |
| `/usr/local/mysql/` | MySQL installation |
| `/usr/local/mysql/var/` | MySQL data (configurable) |
| `/usr/local/php/` | PHP installation |
| `/usr/local/php/etc/php.d/` | PHP extension .ini files |
| `/usr/local/redis/` | Redis (if installed) |
| `/usr/local/acme.sh/` | acme.sh (Let's Encrypt client) |
| `/home/wwwroot/` | Website files |
| `/home/wwwlogs/` | All logs (Nginx, PHP, FPM, mail) |
| `/root/.my.cnf` | MySQL root password (auto-generated) |
| `/root/lnmp-install.log` | Installation log |

## License

MIT
