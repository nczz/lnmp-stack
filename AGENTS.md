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

- domains / aliases: ordinary ASCII or punycode DNS names only
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
| `69` | `EX_UNAVAILABLE` — dependency missing | acme.sh / mysql client could not be installed or found |
| `75` | `EX_TEMPFAIL` — transient, safe to retry | cert issuance failed (DNS not propagated, port 80 blocked) |

`75` specifically means "retry later after fixing the environment" — the
command itself is fine.

---

## 3. SSL certificate issuance — preconditions (READ BEFORE ISSUING)

`lnmp ssl install` / `lnmp vhost add --ssl` uses **acme.sh in webroot mode**
with Let's Encrypt (HTTP-01 challenge). ALL of the following must hold, or
issuance fails with `EX_TEMPFAIL (75)`:

1. **DNS resolves to this host.** The domain's `A` (and `AAAA` if you serve
   IPv6) record must already point to this server and be propagated. Verify:
   ```bash
   dig +short <domain> A          # must return this host's IPv4
   dig +short <domain> AAAA       # must return this host's IPv6 (if applicable)
   ```
2. **A vhost exists and serves the ACME challenge path.** `lnmp vhost add`
   creates a port-80 server block that already allows
   `/.well-known/acme-challenge/`. If issuing SSL separately, add the vhost
   first.
3. **Port 80 is reachable from the internet.** If a firewall is on, open it:
   ```bash
   lnmp firewall allow 80
   ```
   (HTTP-01 validation always hits port 80, even when the final site is HTTPS.)
4. **acme.sh is available**, OR an email is resolvable so it can be installed
   unattended (see §4). If acme.sh cannot be installed, you get
   `EX_UNAVAILABLE (69)`.

If any precondition is unmet, fix it and retry — do not loop blindly.

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
| `vhost add <domain>` | `<domain>` |
| `vhost del <domain>` | `<domain>` |
| `ssl install <domain>` | `<domain>` |
| `ssl revoke <domain>` | `<domain>` |
| `ssl self <domain>` | `<domain>` |
| `db add <name> [user] --password-file <file>` | `<name>` and a root/operator-only password file (user defaults to name) |
| `db del <name>` | `<name>` (user is dropped too, no confirmation prompt) |
| `db import <name> <file>` | `<name>` and an existing `<file>` |
| `db export <name>` | `<name>` |
| `upgrade apply <selection>` | `outdated`, `all`, or one or more component names; an empty selection exits `64` |

Optional values (extra domains, webroot, rewrite, redirect choice) safely fall
back to sensible defaults when not supplied, but supplied values must pass the
allowlists in §1.

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
