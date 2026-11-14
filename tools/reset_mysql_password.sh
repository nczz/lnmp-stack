#!/usr/bin/env bash
# tools/reset_mysql_password.sh — Reset MySQL root password from lnmp.conf
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"

NEW_PASS="${1:-${MySQL_Root_Password:-}}"

if [[ -z "$NEW_PASS" || "$NEW_PASS" = 'your_secure_password_here' ]]; then
    read -r -sp "Enter new MySQL root password: " NEW_PASS
    echo ""
    [[ -n "$NEW_PASS" ]] || { echo "Password cannot be empty."; exit 1; }
fi

# Find mysql binary
MYSQL_BIN=""
for bin in /usr/local/mariadb/bin/mariadb /usr/local/mysql/bin/mysql; do
    [[ -x "$bin" ]] && MYSQL_BIN="$bin" && break
done
[[ -n "$MYSQL_BIN" ]] || { echo "MySQL not found."; exit 1; }

# Try connecting with current /root/.my.cnf
if $MYSQL_BIN -u root -e "SELECT 1;" &>/dev/null; then
    echo "Resetting password via current credentials..."
    $MYSQL_BIN -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}'; FLUSH PRIVILEGES;"

# Try safe mode reset
else
    echo "Cannot connect. Resetting via safe mode..."

    db_svc="mysql"
    systemctl is-active --quiet mariadb 2>/dev/null && db_svc="mariadb"
    systemctl stop "$db_svc"

    MYSQLD_BIN=""
    for bin in /usr/local/mysql/bin/mysqld /usr/local/mariadb/bin/mariadbd; do
        [[ -x "$bin" ]] && MYSQLD_BIN="$bin" && break
    done

    $MYSQLD_BIN --skip-grant-tables --skip-networking --user=mysql &
    SKIP_PID=$!
    sleep 5

    $MYSQL_BIN -u root <<-EOSQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}';
FLUSH PRIVILEGES;
EOSQL

    kill $SKIP_PID 2>/dev/null; wait $SKIP_PID 2>/dev/null
    systemctl start "$db_svc"
    sleep 3
fi

# Update /root/.my.cnf
cat > /root/.my.cnf <<EOF
[client]
user=root
password=${NEW_PASS}
EOF
chmod 600 /root/.my.cnf

# Verify
if $MYSQL_BIN -u root -p"${NEW_PASS}" -e "SELECT 1;" &>/dev/null; then
    echo "✓ Password reset successful."
    echo "  Saved to /root/.my.cnf"
    echo "  Remember to update MySQL_Root_Password in lnmp.conf"
else
    echo "✗ Password reset failed. Check MySQL error log."
    exit 1
fi
