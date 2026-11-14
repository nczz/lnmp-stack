# AGENTS.md — Operating Contract for AI Agents & Automation

This file tells an automated caller (AI agent, CI pipeline, cloud-init,
Terraform, `ssh host 'cmd'`) how to drive the `lnmp` tooling **without getting
stuck on interactive prompts**, and how to satisfy the preconditions for a
successful SSL certificate issuance.

Everything here is fully compatible with human/manual use: the same commands
still prompt interactively when run from a real terminal.

---

## 1. Non-interactive execution model

Every `lnmp` subcommand decides whether to prompt using `is_interactive()`
(defined in `lib/common.sh`). A command runs **non-interactively** (never
blocks on `read`) when ANY of these is true:

| Trigger | How to set |
|---------|-----------|
| stdin is not a TTY | automatic under `ssh host 'cmd'`, pipes, CI |
| `LNMP_ASSUME_YES=1` | `export LNMP_ASSUME_YES=1` or `lnmp --yes ...` |
| `NONINTERACTIVE=1` | `export NONINTERACTIVE=1` |
| `Auto_Install='y'` | set in `lnmp.conf.local` |

> Belt-and-suspenders: `[[ -t 0 ]]` alone is unreliable for CI/agent runs
> (stdin may be neither a TTY nor a pipe). Always pass `--yes` **or** export
> `LNMP_ASSUME_YES=1` when driving `lnmp` from an agent, so behavior is
> deterministic regardless of how stdin is wired.

In non-interactive mode, a missing or invalid **required** value is a hard
error (exit `64`) written to **stderr** — it never silently hangs.

Every third-party probe that can prompt when it inherits a TTY MUST
independently disable interaction, close stdin with `</dev/null`, and enforce a
bounded timeout. Setting `Auto_Install`, `--yes`, or `NONINTERACTIVE` is not
sufficient when the child program implements its own prompts. Composer probes MUST use
`composer_version`, which also sets `COMPOSER_ALLOW_SUPERUSER=1`; agents MUST
NOT invoke the Composer PHAR directly for inventory or verification.

### Global flag

```bash
lnmp --yes <subcommand> ...   # or: lnmp -y <subcommand> ...
```

`--yes` / `-y` may appear anywhere on the line; it is stripped and exported as
`LNMP_ASSUME_YES=1` to every subcommand.

Automation can inspect the command contract without side effects:

```bash
lnmp --help
lnmp vhost add --help
lnmp ssl --help
lnmp ssl install --help
lnmp db --help
lnmp db add --help
lnmp upgrade --help
lnmp upgrade plan
```

Input allowlists are intentionally strict before root-owned files or root SQL
are touched:

- primary domains: ordinary ASCII/punycode DNS names; only DNS-01 certificate
  SANs may use one left-most wildcard (`*.example.com`)
- database and database-user names: `A-Z`, `a-z`, `0-9`, `_`, max 64 chars
- custom webroots: absolute paths without spaces or shell/Nginx metacharacters
- rewrite rules: installed rewrite basename, e.g. `wordpress`, `laravel`, `none`

---

## 2. Exit codes (sysexits.h convention)

Branch on these instead of parsing text:

| Code | Meaning | Typical cause |
|------|---------|---------------|
| `0`  | success | — |
| `64` | `EX_USAGE` — bad/missing argument | required or validated value not supplied / invalid in non-interactive mode |
| `69` | `EX_UNAVAILABLE` — dependency/credential missing | acme.sh, DNS hook, DNS credentials, or mysql client unavailable |
| `75` | `EX_TEMPFAIL` — transient, safe to retry | ACME validation, DNS provider API/propagation/CAA, or port 80 failure |

`75` specifically means "retry later after fixing the environment" — the
command itself is fine.

---

## 3. SSL certificate issuance — preconditions (READ BEFORE ISSUING)

`lnmp ssl install` and `lnmp vhost add --ssl` use Let's Encrypt through the
repository-pinned acme.sh client. **HTTP-01 remains the default.** DNS-01 is an
explicit extension selected with `--challenge dns`; agents MUST NOT silently
change challenge type.

### HTTP-01

All names MUST resolve to this host, share the selected webroot, and be served
by an existing port-80 vhost at `/.well-known/acme-challenge/`. Port 80 MUST be
reachable from the internet even when the final site redirects to HTTPS.

```bash
dig +short <domain> A
dig +short <domain> AAAA
lnmp firewall allow 80
```

### DNS-01

DNS-01 supports wildcard SANs and does not require a vhost, port 80, or A/AAAA
records pointing to this server. It MUST use one of the allowlisted API hooks:
`dns_cf`, `dns_aws`, `dns_ali`, or `dns_dp`. Manual DNS mode is prohibited
because it cannot renew unattended.

Provider credentials MUST be least-privilege TXT record credentials. Supply
them as provider environment variables or an absolute `--dns-credentials`
file containing literal, unquoted `NAME=value` records. That file MUST be a
non-symlink regular file owned by the operator with no group/other access
(mode `600` recommended). Credentials MUST NOT appear in command arguments,
logs, commits, issue comments, or agent output.

| Hook | Required credential source |
|------|----------------------------|
| `dns_cf` | `CF_Token`; optional `CF_Account_ID`, `CF_Zone_ID` |
| `dns_aws` | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`, or ECS/EC2 IAM role |
| `dns_ali` | `Ali_Key` + `Ali_Secret` |
| `dns_dp` | `DP_Id` + `DP_Key` |

Before concluding that DNS-01 is broken, distinguish API authentication,
TXT create/delete permission, authoritative propagation, CAA policy, and CA
rate limits. Exit `69` means the client/hook/credential is unavailable; exit
`75` means issuance or renewal can be retried after correcting the environment.
Never loop blindly.

---

## 4. Registration email for acme.sh

Email is **optional** (Let's Encrypt uses it only for expiry notices), but
supplying it lets acme.sh install and register with zero prompts. Resolution
order (first non-empty wins):

1. `ACME_EMAIL` environment variable
2. `Acme_Email='...'` in `lnmp.conf.local`

```bash
# Either:
export ACME_EMAIL="admin@example.com"
# Or persist in lnmp.conf.local:
echo "Acme_Email='admin@example.com'" >> lnmp.conf.local
```

If no email is found in non-interactive mode, acme.sh is installed **without**
one (still works). Best practice for agents: set `Acme_Email` once in
`lnmp.conf.local`.

---

## 5. Canonical non-interactive recipes

### Provision a WordPress site with SSL in one shot (recommended)
```bash
export LNMP_ASSUME_YES=1
export ACME_EMAIL="admin@example.com"          # optional but recommended

# Preconditions: DNS for site.example.com already points here; port 80 open.
lnmp vhost add site.example.com --rewrite wordpress --ssl --redirect
```
This creates the vhost, issues the LE cert (webroot), installs it, injects the
443 server block, and adds the HTTP→HTTPS 301 redirect.

### Issue / (re)install a cert for an existing vhost
```bash
lnmp --yes ssl install site.example.com
# multi-domain SAN cert (all names must point here and share the webroot):
lnmp --yes ssl install site.example.com --domains "www.example.com"
```

### Issue a wildcard certificate with DNS-01
```bash
install -d -m 700 /etc/lnmp
install -m 600 /dev/null /etc/lnmp/cloudflare-dns.env
printf '%s\n' 'CF_Token=REPLACE_WITH_ZONE_SCOPED_TOKEN' \
  > /etc/lnmp/cloudflare-dns.env
lnmp --yes ssl install site.example.com --domains "*.site.example.com" \
  --challenge dns --dns-provider dns_cf \
  --dns-credentials /etc/lnmp/cloudflare-dns.env
```

The primary name remains non-wildcard so certificate paths and vhost ownership
stay deterministic. acme.sh saves renewal state under `/usr/local/acme.sh`;
LNMP enforces mode `700` on that home and `600` on its configuration files.

### Inventory and apply pinned security upgrades
```bash
# Read-only inventory; safe in monitoring/CI.
lnmp upgrade plan

# Explicit selection:
lnmp --yes upgrade apply nginx php

# Every installed component marked OUTDATED; optional missing components stay absent.
lnmp --yes upgrade apply outdated
```

`apply` never downgrades a component whose runtime version is ahead of the
repository target. Core upgrades keep rollback copies under
`/var/backups/lnmp/`. A database upgrade additionally requires
`/root/.my.cnf`, creates a compressed logical dump before stopping the service,
and retains the previous binary prefix beside the live prefix for atomic
rollback.

### Create a database + user
```bash
install -m 600 /dev/null /root/.lnmp-mydb.pass
printf '%s\n' 'STRONG_PASSWORD_HERE' > /root/.lnmp-mydb.pass
lnmp --yes db add mydb myuser --password-file /root/.lnmp-mydb.pass
```
The password file MUST be readable only by root/the operator (for example
mode `600`). The first line is used as the account password and is not echoed
back to stdout/stderr, so automation logs do not retain database credentials.


### Import a database
```bash
lnmp --yes db import mydb /path/backup.sql        # also accepts .sql.gz
```

### Remove things
```bash
lnmp --yes vhost del site.example.com     # webroot is preserved
lnmp --yes db del mydb                     # also drops the mydb@localhost user
```

---

## 6. Required arguments in non-interactive mode

When you cannot prompt, these MUST be passed as arguments or the command exits `64`:

| Command | Required args |
|---------|---------------|
| `vhost add <domain>` | `<domain>`; DNS-01 additionally requires `--ssl --challenge dns --dns-provider <hook>` and provider credentials/role |
| `vhost del <domain>` | `<domain>` |
| `ssl install <domain>` | `<domain>`; DNS-01 additionally requires `--challenge dns --dns-provider <hook>` and provider credentials/role |
| `ssl revoke <domain>` | `<domain>` |
| `ssl self <domain>` | `<domain>` |
| `db add <name> [user] --password-file <file>` | `<name>` and a root/operator-only password file (user defaults to name) |
| `db del <name>` | `<name>` (user is dropped too, no confirmation prompt) |
| `db import <name> <file>` | `<name>` and an existing `<file>` |
| `db export <name>` | `<name>` |
| `upgrade apply <selection>` | `outdated`, `all`, or one or more component names; an empty selection exits `64` |

HTTP-01 remains the default. Optional values fall back safely, but supplied
domains, webroots, rewrites, challenge settings, providers, propagation waits,
and secret files MUST pass the allowlists and ownership/mode checks above.

---

## 7. Upgrade safety contract

`lnmp upgrade plan` is read-only and does not require root. `apply` requires
root and accepts these component names:

```text
nginx php db redis memcached composer wp-cli acme
ext:redis ext:imagick ext:apcu ext:swoole ext:memcached ext:imap
phpmyadmin (legacy vulnerable deployment removal only)
```

`outdated` and `all` mean the same conservative operation: upgrade only
installed patch-level components marked `OUTDATED`. They do not install
missing optional components and do not apply items marked `REVIEW`.
Nginx/PHP/database release-series transitions and Redis major-version
transitions are marked `REVIEW`; automation must name those components
explicitly after application compatibility has been assessed. A selected
`AHEAD` component is rejected rather than downgraded.

Every apply run creates a root-only log under `/var/log/lnmp/`. Core rollback
copies remain under `/var/backups/lnmp/`, and rollback service health is
reported as completed or failed. The legacy `phpmyadmin` target creates a
root-only backup and removes the web-served copy; the current upstream release
has no complete security fix. For database changes, preserve both the logical
dump and previous binary prefix until application checks pass. Binary rollback
is best-effort after database metadata migration; the logical dump is the
authoritative recovery path.

## 8. Configuration-preserving upgrade and agent collaboration contract

An upgrade is complete only when the component version, active configuration,
loaded capabilities, service health, and application-facing behavior are all
accounted for. Replacing a binary while silently resetting tuning is a failed
upgrade.

### Configuration ownership

| Class | Examples | Required behavior |
|-------|----------|-------------------|
| Operator-owned active configuration | `php.ini`, `php-fpm.conf`, `php-fpm.d/*`, non-security `php.d/*`, Nginx/Redis configs, `/etc/my.cnf`, service overrides | Preserve content, mode, owner, and group. Never replace it with a repository template during upgrade. |
| Project-managed security overlay | `php.d/99-lnmp-security.ini` | May be updated to the pinned security baseline; record the change in the protected configuration diff. |
| Fresh-install template | files under `conf/` and `systemd/` | Generate defaults only for a fresh install. An upgrade may use them for comparison, but must not overwrite operator tuning. |
| Binary-owned sample/default | `*.default` emitted by upstream `make install` | Not active configuration. Do not mistake a changed sample for a successful migration. |

The PHP upgrader preserves the active PHP/FPM configuration and extension INI
files, writes before/after module inventories, rebuilds every installed
extension supported by `lib/extensions.sh`, and fails plus rolls back if a
previously loaded module disappears. An unknown dynamic extension blocks the
upgrade before binaries change; an agent must add pinned source, checksum,
dependencies, build options, and tests to the extension registry rather than
discarding it. The managed security overlay is the only allowed automatic PHP
configuration change.

For the repository's single managed `[www]` pool, fresh installs MUST keep CLI
`disable_functions` empty for WP-CLI/Composer, set `enable_dl=Off`, and apply
the configurable `PHP_FPM_DISABLE_FUNCTIONS` list only through the FPM pool's
`php_admin_value`. The compatibility-first default blocks process creation:
`exec,passthru,shell_exec,system,popen,proc_open,pcntl_exec,pcntl_fork`.
Agents MUST NOT add filesystem, logging, socket, or IMAP functions to the
global default without an explicit workload requirement and plugin smoke.
Changing this list on an existing host is a reviewed configuration migration,
not a package upgrade: back up the active file, preserve CLI behavior, run
`php-fpm -t`, exercise backup/media/mail/security plugins, and roll back on any
undefined-function failure.

Nginx, Redis, Memcached, and database upgrades snapshot their active
configuration and service unit where applicable, compare it before service
activation, and retain protected diff evidence with the rollback backup.

### Mandatory agent workflow

An AI agent changing versions or running an upgrade MUST:

1. **Inventory reality before editing.** Run `lnmp upgrade plan`; record OS and
   architecture, runtime versions, active service units, install/data paths,
   Nginx `-V`, PHP `--ini`/`-m`/`php-config --configure-options`, configured
   PHP extension directives, database engine/data directory, and Redis
   endpoint. Never infer these from repository defaults.
2. **Align against primary information.** Check the upstream lifecycle page,
   release notes, migration guide, and security advisories for every changed
   release series. Update `versions.conf` with an immutable HTTPS artifact and
   verified SHA-256. Record the security review date; never claim permanent
   “no CVEs.”
3. **Classify configuration ownership.** Identify operator-owned files,
   project-managed overlays, generated files, custom modules/extensions, and
   secret-bearing files before mutation.
4. **Plan compatibility explicitly.** Same-series patches may be `OUTDATED`.
   Release-series transitions stay `REVIEW` until application and data
   compatibility are assessed. Unknown modules or architecture gaps block the
   run; they are not silently removed.
5. **Use the repository path.** Fix generic upgrade code and tests first. Never
   leave a host-only command, edited binary, ad-hoc config rewrite, or
   hostname-specific workaround as the delivered solution.
6. **Capture rollback evidence.** Preserve binaries/prefixes, active
   configuration, version state, module inventory, and database logical dump
   where applicable. Logs and diffs must remain root-only.
7. **Verify effective behavior after deployment.** Compare protected
   configuration and loaded modules, run native config tests, restart and
   check readiness, exercise HTTP/database/cache paths, and run an
   application-specific smoke for every hosted workload affected by a
   release-series change.
8. **Fail safely.** On an unexplained difference, missing capability, failed
   migration, or failed smoke, stop and roll back. Report the exact backup,
   config diff, and run log. Do not suppress the error or weaken validation.
9. **Release only proved behavior.** Run syntax and warning-clean ShellCheck,
   behavior tests, the supported Ubuntu matrix, and a real changed-path smoke.
   Update README/CHANGELOG, then commit, tag, push, publish, and confirm CI.

For a PHP upgrade, the expected alignment is concrete:

- PHP runtime version equals `PHP_VER` in `versions.conf`.
- Every project-supported dynamic extension that was loaded before remains
  loaded and is rebuilt against the new PHP API.
- `php.ini`, `php-fpm.conf`, pool files, extension tuning, and the PHP-FPM
  systemd unit retain their pre-upgrade content and metadata.
- `99-lnmp-security.ini` equals the repository security baseline.
- `php-fpm -t`, service readiness, module comparison, and application smoke
  all pass.

---

## 9. Human compatibility (unchanged)

Run any command **without** arguments from a real terminal and it prompts
interactively exactly as before. The non-interactive guards only take effect
when there is no TTY or when `--yes`/`NONINTERACTIVE`/`Auto_Install` is set.
There is a single code path for both modes — no separate "agent mode" to keep
in sync.
