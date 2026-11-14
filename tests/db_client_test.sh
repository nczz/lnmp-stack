#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/mysql.sh"
LOG_FILE="${TEST_TMP}/db-client.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_link() {
    local link="$1" target="$2"
    [[ -L "$link" ]] || fail "missing client link: ${link}"
    [[ "$(readlink "$link")" = "$target" ]] \
        || fail "${link} points to $(readlink "$link"), expected ${target}"
}

MARIADB_PREFIX="${TEST_TMP}/mariadb"
LINK_DIR="${TEST_TMP}/bin"
mkdir -p "${MARIADB_PREFIX}/bin" "$LINK_DIR"
for client in mariadb mariadb-dump mariadb-check mariadb-admin mariadb-import; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${MARIADB_PREFIX}/bin/${client}"
    chmod +x "${MARIADB_PREFIX}/bin/${client}"
done

_install_database_client_links mariadb "$MARIADB_PREFIX" "$LINK_DIR"
for client in mariadb mariadb-dump mariadb-check mariadb-admin mariadb-import; do
    assert_link "${LINK_DIR}/${client}" "${MARIADB_PREFIX}/bin/${client}"
done
assert_link "${LINK_DIR}/mysql" "${MARIADB_PREFIX}/bin/mariadb"
assert_link "${LINK_DIR}/mysqldump" "${MARIADB_PREFIX}/bin/mariadb-dump"
assert_link "${LINK_DIR}/mysqladmin" "${MARIADB_PREFIX}/bin/mariadb-admin"
assert_link "${LINK_DIR}/mysqlcheck" "${MARIADB_PREFIX}/bin/mariadb-check"
assert_link "${LINK_DIR}/mysqlimport" "${MARIADB_PREFIX}/bin/mariadb-import"

# Reconciliation must be idempotent and replace stale project-owned links.
ln -sfn /missing/client "${LINK_DIR}/mariadb"
_install_database_client_links mariadb "$MARIADB_PREFIX" "$LINK_DIR"
assert_link "${LINK_DIR}/mariadb" "${MARIADB_PREFIX}/bin/mariadb"

MYSQL_PREFIX="${TEST_TMP}/mysql"
mkdir -p "${MYSQL_PREFIX}/bin"
for client in mysql mysqldump mysqladmin mysqlcheck mysqlimport; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${MYSQL_PREFIX}/bin/${client}"
    chmod +x "${MYSQL_PREFIX}/bin/${client}"
done
_install_database_client_links mysql "$MYSQL_PREFIX" "$LINK_DIR"
for client in mysql mysqldump mysqladmin mysqlcheck mysqlimport; do
    assert_link "${LINK_DIR}/${client}" "${MYSQL_PREFIX}/bin/${client}"
done

printf 'db_client_test: PASS\n'
