#!/usr/bin/env bash
# tools/upgrade.sh — Plan and apply pinned LNMP component upgrades
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/versions.conf"
source "${LNMP_DIR}/lnmp.conf"
# shellcheck source=/dev/null
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
source "${LNMP_DIR}/lib/common.sh"
source "${LNMP_DIR}/lib/upgrade.sh"

show_usage() {
    cat <<'EOF'
Usage:
  lnmp upgrade plan
  lnmp upgrade apply <outdated|all|component...>

Commands:
  plan                    Read-only inventory of installed and pinned versions.
  apply outdated          Upgrade every installed component marked OUTDATED.
  apply all               Alias for 'apply outdated'; missing options stay absent.
  apply <component...>    Upgrade only the selected installed components.

Components:
  nginx php db redis memcached composer wp-cli acme
  ext:redis ext:imagick ext:apcu ext:swoole ext:memcached ext:imap
  phpmyadmin (legacy vulnerable deployment removal only)

Safety:
  - apply requires root; plan does not.
  - Missing optional components are never installed by 'outdated' or 'all'.
  - Newer-than-target versions are never downgraded.
  - Concurrent apply runs are rejected with a process lock.
  - Core service upgrades retain rollback copies under /var/backups/lnmp/.
  - Database upgrades require /root/.my.cnf and create a logical dump first.
  - Legacy phpMyAdmin is backed up root-only, then removed from the webroot.

Examples:
  lnmp upgrade plan
  lnmp --yes upgrade apply nginx php
  lnmp --yes upgrade apply outdated
EOF
}

case "${1:-}" in
    plan)
        shift
        [[ $# -eq 0 ]] || die_code "$EX_USAGE" "Usage: lnmp upgrade plan"
        upgrade_plan
        ;;
    apply)
        shift
        upgrade_apply "$@"
        ;;
    --help|-h|help)
        show_usage
        ;;
    '')
        show_usage
        exit "$EX_USAGE"
        ;;
    *)
        show_usage
        die_code "$EX_USAGE" "Unknown upgrade command: $1"
        ;;
esac
