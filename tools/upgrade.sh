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
  lnmp upgrade inspect
  lnmp upgrade adopt
  lnmp upgrade apply <outdated|all|component...>
  lnmp upgrade cleanup [--dry-run]
Commands:
  plan                    Read-only installed-versus-pinned version inventory.
  inspect                 Read-only service ownership, configuration, capacity,
                          extension, and version preflight for an existing host.
  adopt                   Validate an older lnmp-stack installation, capture a
                          protected manifest, and initialize runtime state.
  apply outdated          Upgrade installed patch-level items marked OUTDATED.
  apply all               Alias for 'apply outdated'; missing options and
                          release-series transitions stay unchanged.
  apply <component...>    Upgrade selected installed components; explicit
                          selection is required for items marked REVIEW.
  cleanup [--dry-run]     Remove transient source/build cache and expire only
                          completed rollback backups under the retention policy.

Components:
  nginx php db redis memcached composer wp-cli acme
  ext:redis ext:imagick ext:apcu ext:swoole ext:memcached ext:imap
  phpmyadmin (legacy vulnerable deployment removal only)

Safety:
  - inspect and plan are read-only; adopt, apply, and cleanup require root.
  - Missing optional components are never installed by 'outdated' or 'all'.
  - Newer-than-target versions are never downgraded.
  - Nginx/PHP/database release-series and Redis major transitions are marked
    REVIEW and require explicit component selection.
  - Concurrent adopt/apply/cleanup runs are rejected with a process lock.
  - Apply refuses unmanaged service processes, invalid live configuration,
    unsupported PHP config-root/scan-dir migrations, and insufficient free space.
  - Per-run logs are protected under /var/log/lnmp/.
  - Core service upgrades retain rollback copies under /var/backups/lnmp/.
  - Rollback service health is verified and reported as completed or failed.
  - Transient source/build cache is removed after apply, including failures.
  - Cleanup retains at least three completed backups and never removes pending,
    rolled-back, failed, or unclassified legacy backups.
  - Database upgrades require /root/.my.cnf and create a logical dump first.
  - Legacy phpMyAdmin is backed up root-only, then removed from the webroot.
  - Active service configuration is snapshotted and must remain unchanged.
  - PHP extension INI tuning and loaded modules must survive PHP replacement.
  - Unmanaged PHP extensions are retained for same-series patches and block ABI transitions.

Examples:
  lnmp upgrade inspect
  sudo lnmp --yes upgrade adopt
  lnmp upgrade plan
  sudo lnmp --yes upgrade apply nginx php
  sudo lnmp --yes upgrade apply outdated
  sudo lnmp --yes upgrade cleanup --dry-run
  sudo lnmp --yes upgrade cleanup
EOF
}

case "${1:-}" in
    plan)
        shift
        [[ $# -eq 0 ]] || die_code "$EX_USAGE" "Usage: lnmp upgrade plan"
        upgrade_plan
        ;;
    inspect)
        shift
        [[ $# -eq 0 ]] || die_code "$EX_USAGE" "Usage: lnmp upgrade inspect"
        LOG_FILE=/dev/null
        upgrade_inspect
        ;;
    adopt)
        shift
        [[ $# -eq 0 ]] || die_code "$EX_USAGE" "Usage: lnmp upgrade adopt"
        upgrade_adopt
        ;;
    apply)
        shift
        upgrade_apply "$@"
        ;;
    cleanup)
        shift
        case "${1:-}" in
            '') upgrade_cleanup n ;;
            --dry-run)
                shift
                [[ $# -eq 0 ]] || die_code "$EX_USAGE" "Usage: lnmp upgrade cleanup [--dry-run]"
                upgrade_cleanup y
                ;;
            *) die_code "$EX_USAGE" "Usage: lnmp upgrade cleanup [--dry-run]" ;;
        esac
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
