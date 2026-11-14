#!/usr/bin/env bash
# tools/uninstall.sh — Uninstall LNMP stack
# Normal mode: backup DB + configs, preserve website files
# Reset mode (--reset): remove everything for clean reinstall
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

MODE='normal'
[[ "${1:-}" = '--reset' ]] && MODE='reset'

echo "+---------------------------------------------------+"
echo "|          LNMP Stack Uninstaller                    |"
echo "+---------------------------------------------------+"
echo ""

if [[ "$MODE" = 'reset' ]]; then
    echo -e "${RED}RESET MODE: Everything will be removed for clean reinstall.${NC}"
    echo "  - All installed software"
    echo "  - All configs, logs, website files, databases"
    echo ""
    read -r -p "Type 'reset' to confirm: " confirm
    [[ "$confirm" = "reset" ]] || { echo "Cancelled."; exit 0; }
else
    echo "Normal uninstall:"
    echo "  - Website files in /home/wwwroot/ will be PRESERVED"
    echo "  - Databases will be backed up to /root/db_backup_*"
    echo "  - Nginx/PHP configs will be backed up"
    echo ""
    read -r -p "Type 'yes' to confirm: " confirm
    [[ "$confirm" = "yes" ]] || { echo "Cancelled."; exit 0; }
fi

echo ""

# ─── Backup (normal mode only) ───

if [[ "$MODE" = 'normal' ]]; then
    BACKUP_DIR="/root/lnmp_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    # Backup databases
    MYSQL_BIN=""
    for bin in /usr/local/mariadb/bin/mariadb /usr/local/mysql/bin/mysql; do
        [[ -x "$bin" ]] && MYSQL_BIN="$bin" && break
    done
    MYSQLDUMP_BIN=""
    for bin in /usr/local/mariadb/bin/mariadb-dump /usr/local/mysql/bin/mysqldump; do
        [[ -x "$bin" ]] && MYSQLDUMP_BIN="$bin" && break
    done

    if [[ -n "$MYSQL_BIN" && -n "$MYSQLDUMP_BIN" ]]; then
        # Check if MySQL is running and accessible
        if $MYSQL_BIN -u root -e "SELECT 1;" &>/dev/null; then
            echo -e "${GREEN}Backing up databases...${NC}"
            mkdir -p "$BACKUP_DIR/db"
            databases=$($MYSQL_BIN -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|sys)$')
            for db in $databases; do
                echo "  Dumping ${db}..."
                $MYSQLDUMP_BIN --single-transaction --quick "$db" 2>/dev/null | gzip > "${BACKUP_DIR}/db/${db}.sql.gz"
            done
        else
            echo -e "${YELLOW}MySQL not accessible, copying raw data directory...${NC}"
            for data_dir in /usr/local/mysql/var /usr/local/mariadb/var; do
                [[ -d "$data_dir" ]] && cp -a "$data_dir" "${BACKUP_DIR}/db_raw/" 2>/dev/null
            done
        fi
    fi

    # Backup configs
    echo "Backing up configs..."
    mkdir -p "$BACKUP_DIR/conf"
    [[ -d /usr/local/nginx/conf ]] && cp -a /usr/local/nginx/conf "$BACKUP_DIR/conf/nginx/" 2>/dev/null
    [[ -d /usr/local/php/etc ]] && cp -a /usr/local/php/etc "$BACKUP_DIR/conf/php/" 2>/dev/null
    [[ -f /etc/my.cnf ]] && cp /etc/my.cnf "$BACKUP_DIR/conf/" 2>/dev/null
    [[ -f /root/.my.cnf ]] && cp /root/.my.cnf "$BACKUP_DIR/conf/" 2>/dev/null

    echo -e "${GREEN}Backup saved to: ${BACKUP_DIR}${NC}"
    echo ""
fi

# ─── Stop services ───

echo "Stopping services..."
for svc in nginx php-fpm mysql mariadb redis; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
killall -9 nginx mysqld mariadbd php-fpm redis-server 2>/dev/null || true
sleep 1

# ─── Remove installations ───

echo "Removing installed software..."
rm -rf /usr/local/nginx
rm -rf /usr/local/mysql
rm -rf /usr/local/mariadb
rm -rf /usr/local/php
rm -rf /usr/local/redis
rm -rf /usr/local/acme.sh

# jemalloc
rm -f /usr/local/lib/libjemalloc*
rm -rf /usr/local/include/jemalloc
rm -f /usr/local/bin/jemalloc*

# ─── Remove systemd units ───

echo "Removing systemd units..."
rm -f /etc/systemd/system/{nginx,mysql,mariadb,php-fpm,redis}.service
systemctl daemon-reload

# ─── Remove symlinks ───

echo "Removing symlinks..."
rm -f /usr/bin/{nginx,mysql,mysqldump,mysqlcheck,mysqladmin,mysqlimport,mariadb,mariadb-dump,mariadb-check,mariadb-admin,mariadb-import,php,phpize,php-config,pecl,php-fpm,redis-cli,redis-server,lnmp,wp}
rm -f /usr/local/bin/{composer,wp}

# ─── Remove configs ───

echo "Removing system configs..."
rm -f /etc/my.cnf
rm -f /root/.my.cnf
rm -f /etc/ld.so.conf.d/{mysql,mariadb}.conf
ldconfig

# ─── Remove logs and data (reset mode) or preserve (normal mode) ───

if [[ "$MODE" = 'reset' ]]; then
    echo "Removing website files, logs, and all data..."
    rm -rf /home/wwwroot
    rm -rf /home/wwwlogs
    rm -f /root/lnmp-install.log

    # Remove www/mysql users
    userdel www 2>/dev/null || true
    userdel mysql 2>/dev/null || true

    # Clean src cache (keep downloaded tarballs for faster reinstall)
    # Use --purge to also remove src cache
    if [[ "${2:-}" = '--purge' ]]; then
        SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
        [[ -d "${SCRIPT_DIR}/src" ]] && rm -rf "${SCRIPT_DIR}/src/"*
    fi
else
    echo "Preserving /home/wwwroot/ (website files)"
    echo "Preserving /home/wwwlogs/ (logs)"
fi

# ─── Summary ───

echo ""
echo "+---------------------------------------------------+"
if [[ "$MODE" = 'reset' ]]; then
    echo "|  Reset complete. Ready for clean reinstall.        |"
    echo "+---------------------------------------------------+"
    echo ""
    echo "  Run: cd ~/lnmp-stack && sudo ./install.sh lnmp"
else
    echo "|  Uninstall complete.                               |"
    echo "+---------------------------------------------------+"
    echo ""
    echo "  Backup:   ${BACKUP_DIR}"
    echo "  Website:  /home/wwwroot/ (preserved)"
    echo "  Logs:     /home/wwwlogs/ (preserved)"
fi
