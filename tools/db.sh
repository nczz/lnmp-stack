#!/usr/bin/env bash
# tools/db.sh — Database management
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "${LNMP_DIR}/lnmp.conf" ]] && source "${LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
[[ -f "${LNMP_DIR}/lib/common.sh" ]] && source "${LNMP_DIR}/lib/common.sh"


_run_mysql_root() {
    local bin="$1"
    shift

    local defaults_file="" rc
    if [[ -n "${MySQL_Root_Password:-}" && "${MySQL_Root_Password}" != 'your_secure_password_here' ]]; then
        defaults_file="$(mktemp)" || die_code "$EX_UNAVAILABLE" "Cannot create temporary MySQL defaults file."
        chmod 600 "$defaults_file"
        printf '[client]\nuser=root\npassword=%s\n' "${MySQL_Root_Password}" > "$defaults_file"
        set +e
        "$bin" --defaults-extra-file="$defaults_file" "$@"
        rc=$?
        set -e
        rm -f "$defaults_file"
        return "$rc"
    elif [[ -f /root/.my.cnf ]]; then
        "$bin" "$@"
    else
        "$bin" -u root "$@"
    fi
}

_mysql_cmd() {
    local mysql_bin=""
    for bin in /usr/local/mysql/bin/mysql /usr/local/mariadb/bin/mysql /usr/bin/mysql; do
        [[ -x "$bin" ]] && mysql_bin="$bin" && break
    done
    [[ -n "$mysql_bin" ]] || die_code "$EX_UNAVAILABLE" "MySQL client not found."

    _run_mysql_root "$mysql_bin" "$@"
}

show_add_usage() {
    cat <<'EOF'
Usage:
  lnmp db add <name> [user] --password-file /path/to/secret
  db.sh add <name> [user] --password-file /path/to/secret

Required:
  <name>                    Database name: A-Z, a-z, 0-9, _, max 64 chars.
  --password-file <file>    First line is used as the user password.

Optional:
  [user]                    Database user; defaults to <name>. Same name rules.
  --help, -h                Show this help.

Agent / CI rules:
  - Use lnmp --yes db add ... --password-file <file>.
  - Non-interactive mode rejects positional passwords to avoid process-list and
    shell-history leaks.
  - Password file must be readable and not group/other-readable, e.g. mode 600.
  - The supplied password is not echoed to stdout/stderr.

Examples:
  install -m 600 /dev/null /root/.lnmp-mysite.pass
  printf '%s\n' 'STRONG_PASSWORD_HERE' > /root/.lnmp-mysite.pass
  lnmp --yes db add mysite myuser --password-file /root/.lnmp-mysite.pass
EOF
}

_require_option_arg() {
    local opt="$1" value="${2:-}"
    [[ -n "$value" && "$value" != -* ]] || {
        show_add_usage
        die_code "$EX_USAGE" "Missing value for ${opt}."
    }
}

_read_secret_file() {
    local file="$1" mode=""
    [[ -f "$file" && -r "$file" ]] || die_code "$EX_USAGE" "Password file not readable: ${file}"
    mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)
    if [[ -n "$mode" ]] && (( (10#$mode % 100) != 0 )); then
        die_code "$EX_USAGE" "Password file must not be readable by group/other: ${file}"
    fi

    local secret
    IFS= read -r secret < "$file" || true
    [[ -n "$secret" ]] || die_code "$EX_USAGE" "Password file is empty: ${file}"
    printf '%s' "$secret"
}


db_add() {
    local dbname="" dbuser="" dbpass="" password_file="" positional_password_seen="n"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --password-file)
                _require_option_arg "$1" "${2:-}"
                password_file="$2"
                shift 2
                ;;
            --help|-h)
                show_add_usage
                exit 0
                ;;
            -*)
                show_add_usage
                die_code "$EX_USAGE" "Unknown option: $1"
                ;;
            *)
                if [[ -z "$dbname" ]]; then
                    dbname="$1"
                elif [[ -z "$dbuser" ]]; then
                    dbuser="$1"
                elif [[ -z "$dbpass" ]]; then
                    dbpass="$1"
                    positional_password_seen="y"
                else
                    show_add_usage
                    die_code "$EX_USAGE" "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$dbname" ]] || { is_interactive && read -r -p "Database name: " dbname; }
    [[ -n "$dbname" ]] || die_code "$EX_USAGE" "Database name required. Usage: db.sh add <name> [user] --password-file /path/to/secret"

    [[ -n "$dbuser" ]] || { is_interactive && read -r -p "Username (default: ${dbname}): " dbuser; }
    dbuser="${dbuser:-$dbname}"

    if [[ -n "$password_file" ]]; then
        dbpass="$(_read_secret_file "$password_file")"
    elif [[ "$positional_password_seen" = "y" ]] && ! is_interactive; then
        die_code "$EX_USAGE" "Password file required in non-interactive mode. Usage: db.sh add <name> [user] --password-file /path/to/secret"
    fi
    [[ -n "$dbpass" ]] || { is_interactive && { read -r -sp "Password: " dbpass; echo ""; }; }
    [[ -n "$dbpass" ]] || die_code "$EX_USAGE" "Password required. Usage: db.sh add <name> [user] --password-file /path/to/secret"

    validate_mysql_name "database name" "$dbname"
    validate_mysql_name "database user" "$dbuser"
    local dbpass_sql
    dbpass_sql="$(sql_escape_string "$dbpass")"


    _mysql_cmd <<SQL
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass_sql}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
SQL

    echo "Database '${dbname}' created."
    echo "  User: ${dbuser}@localhost"
    echo "  Pass: (provided; not displayed)"
}

db_del() {
    local dbname="${1:-}"
    [[ -n "$dbname" ]] || { is_interactive && read -r -p "Database to delete: " dbname; }
    [[ -n "$dbname" ]] || die_code "$EX_USAGE" "Database name required. Usage: db.sh del <name>"

    validate_mysql_name "database name" "$dbname"

    local drop_user="y"
    if is_interactive; then
        read -r -p "Also drop user '${dbname}'@'localhost'? [Y/n]: " drop_user
    fi

    _mysql_cmd -e "DROP DATABASE IF EXISTS \`${dbname}\`;" 2>&1

    if [[ ! "${drop_user}" =~ ^[Nn]$ ]]; then
        _mysql_cmd -e "DROP USER IF EXISTS '${dbname}'@'localhost'; FLUSH PRIVILEGES;" 2>&1
    fi

    echo "Database '${dbname}' deleted."
}

db_list() {
    echo "=== Databases ==="
    _mysql_cmd -e "SHOW DATABASES;" 2>&1
    echo ""
    echo "=== Users ==="
    _mysql_cmd -e "SELECT User, Host FROM mysql.user WHERE User NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','debian-sys-maint');" 2>&1
}

db_import() {
    local dbname="${1:-}"
    local sqlfile="${2:-}"

    [[ -n "$dbname" ]] || { is_interactive && read -r -p "Database name: " dbname; }
    [[ -n "$dbname" ]] || die_code "$EX_USAGE" "Database name required. Usage: db.sh import <name> <file.sql[.gz]>"
    [[ -n "$sqlfile" ]] || { is_interactive && read -r -p "SQL file path: " sqlfile; }
    [[ -n "$sqlfile" ]] || die_code "$EX_USAGE" "SQL file required. Usage: db.sh import <name> <file.sql[.gz]>"
    [[ -f "$sqlfile" ]] || die_code "$EX_USAGE" "File not found: ${sqlfile}"

    validate_mysql_name "database name" "$dbname"

    echo "Importing ${sqlfile} into ${dbname}..."
    case "$sqlfile" in
        *.gz)  zcat "$sqlfile" | _mysql_cmd -- "$dbname" ;;
        *.sql) _mysql_cmd -- "$dbname" < "$sqlfile" ;;
        *)     _mysql_cmd -- "$dbname" < "$sqlfile" ;;
    esac
    echo "Import complete."
}

db_export() {
    local dbname="${1:-}"
    [[ -n "$dbname" ]] || { is_interactive && read -r -p "Database name: " dbname; }
    [[ -n "$dbname" ]] || die_code "$EX_USAGE" "Database name required. Usage: db.sh export <name>"

    validate_mysql_name "database name" "$dbname"

    local dump_bin=""
    for bin in /usr/local/mysql/bin/mysqldump /usr/local/mariadb/bin/mysqldump /usr/bin/mysqldump; do
        [[ -x "$bin" ]] && dump_bin="$bin" && break
    done
    [[ -n "$dump_bin" ]] || die_code "$EX_UNAVAILABLE" "mysqldump not found."

    local outfile
    outfile="${dbname}_$(date +%Y%m%d_%H%M%S).sql.gz"

    _run_mysql_root "$dump_bin" --single-transaction --quick -- "$dbname" | gzip > "$outfile"

    echo "Exported: ${outfile} ($(du -h "$outfile" | cut -f1))"
}

show_usage() {
    cat <<'EOF'
Usage:
  lnmp db {add|del|list|import|export}
  db.sh {add|del|list|import|export}

Commands:
  add <name> [user] --password-file <file>
                        Create database and localhost user. See: lnmp db add --help
  del <name>            Drop database; non-interactive mode also drops same-name user.
  list                  List databases and non-system users.
  import <name> <file>  Import .sql or .sql.gz into database.
  export <name>         Export database to <name>_YYYYmmdd_HHMMSS.sql.gz.

Agent / CI rules:
  - Use lnmp --yes db ... for deterministic non-interactive execution.
  - Database/user names are allowlisted to A-Z, a-z, 0-9, _, max 64 chars.
  - Use --password-file for db add secrets; positional passwords are rejected
    in non-interactive mode.
  - Exit 64 = bad/missing/invalid input; 69 = mysql/mysqldump unavailable.
EOF
}

has_help_arg() {
    local arg
    for arg in "$@"; do
        case "$arg" in --help|-h|help) return 0 ;; esac
    done
    return 1
}

reject_extra_args() {
    local usage="$1"
    shift
    [[ $# -eq 0 ]] && return 0
    show_usage
    die_code "$EX_USAGE" "Unexpected argument: $1. Usage: ${usage}"
}



case "${1:-}" in
    add)    shift; db_add "$@" ;;
    del)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp db del <name>"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        db_del "$@"
        ;;
    list|ls)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp db list"; exit 0; fi
        reject_extra_args "lnmp db list" "$@"
        db_list
        ;;
    import)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp db import <name> <file.sql[.gz]>"; exit 0; fi
        [[ $# -le 2 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $3"; }
        db_import "$@"
        ;;
    export)
        shift
        if has_help_arg "$@"; then echo "Usage: lnmp db export <name>"; exit 0; fi
        [[ $# -le 1 ]] || { show_usage; die_code "$EX_USAGE" "Unexpected argument: $2"; }
        db_export "$@"
        ;;
    --help|-h|help) show_usage; exit 0 ;;
    "")
        show_usage
        exit 64
        ;;
    *)
        show_usage
        exit 64
        ;;
esac
