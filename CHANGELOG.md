# Changelog

All notable changes to this project are documented in this file.

## v1.7.10 — 2026-11-14

### Unattended Composer Probes

- Prevent root Composer version checks from blocking unattended installs or upgrades that inherit a TTY by centralizing probes with `--no-interaction`, closed stdin, explicit superuser intent, and a hard timeout.
- Report probe failures and timeouts on stderr, and cover argument, stdin, environment, parsing, and timeout behavior with regression tests.

## v1.7.9 — 2026-11-13

### WordPress PHP Policy

- Keep CLI process functions available for WP-CLI and Composer while applying a configurable, compatibility-first process-execution denylist only to the PHP-FPM `[www]` pool.
- Disable runtime extension loading with `enable_dl=Off`, reject malformed or duplicate FPM function lists, and stop disabling filesystem, logging, IMAP, and unrelated functions by default.
- Remove the dead optional pool-template copy and add generated-configuration tests for CLI/FPM separation, tuning, overrides, and invalid policy input.

## v1.7.8 — 2026-11-13

### Bug Fixes

- Initialize the PHP configuration-summary accumulator under `set -u` and cover the real `upgrade plan` summary path in behavior tests.

## v1.7.7 — 2026-11-13

### Configuration-Preserving Upgrades

- Preserve and compare active Nginx, PHP/PHP-FPM, Redis, Memcached, database, and systemd configuration during binary upgrades, retaining protected diff evidence with rollback backups.
- Preserve PHP extension INI tuning, inventory loaded modules before and after replacement, rebuild registered extensions, and reject unmanaged dynamic extensions before changing binaries.
- Define an AI-agent upgrade contract covering upstream/security alignment, configuration ownership, compatibility review, generic fixes, rollback evidence, changed-path smoke tests, and release gates.

## v1.7.6 — 2026-11-13

### CI and Compatibility

- Pass explicit install-mode defaults at optional-argument call sites and isolate upgrade-test fixtures so the warning-clean ShellCheck gate remains portable across ShellCheck releases.

## v1.7.5 — 2026-11-13

### Upgrade Safety and Compatibility

- Treat Nginx, PHP, and database release-series transitions plus Redis major-version transitions as `REVIEW`, requiring explicit selection instead of applying them through the conservative `outdated` batch.
- Add root-only per-run upgrade logs, prerequisite diagnostics, verified rollback health reporting, Redis readiness support for password-protected and custom-endpoint instances, custom Nginx module preservation checks, and rollback coverage for Nginx's dynamically linked jemalloc/LuaJIT libraries.
- Add behavior tests for historical v1.3 and v1.6 version transitions, selection safety, refusal exit codes, custom-module/Redis-endpoint handling, warning-clean ShellCheck enforcement, and an Ubuntu 22.04/24.04/26.04 CI compatibility matrix.

## v1.7.4 — 2026-11-13

### Bug Fixes

- Wait for Redis to accept commands after a service restart before deciding whether an upgrade succeeded, eliminating a startup race that caused healthy deployments to be rolled back.

## v1.7.3 — 2026-11-13

### Bug Fixes

- Build Redis 8.10 through its explicit core-only target, preventing standalone Redis upgrades from requiring the optional Redis Stack module toolchains.

## v1.7.2 — 2026-11-13

### Bug Fixes

- Keep the PECL extension registry global when upgrade tooling loads build libraries from a function, preventing `set -u` from aborting PHP upgrades before installed extensions are rebuilt.

## v1.7.1 — 2026-11-12

### Ubuntu 26.04 Validation

- Validate the complete default component path on Ubuntu 26.04.1 amd64: Nginx with the patched OpenSSL baseline, MariaDB, PHP, default PECL extensions, Composer, WP-CLI, service listeners, database queries, and upgrade inventory.
- Allow minimal Ubuntu installations without `sudo`, and explicitly install the `iproute2` and `iputils-ping` runtime tools used by verification and DNS checks.
- Set `/etc/my.cnf` to mode `0644` explicitly so a permissive caller umask cannot make MariaDB reject the configuration as unsafe.
- Recognize both current `mariadb from VERSION-MariaDB` and legacy `Distrib VERSION` client output in `lnmp upgrade plan`.
- Remove the obsolete PECL libsodium path from addon and upgrade handling. PHP 8.4 provides sodium as a built-in extension; treating it as PECL caused a false `AHEAD` result and could attempt an invalid rebuild after PHP upgrades.

## v1.7.0 — 2026-11-12

### Security and Supply Chain

- Require HTTPS and a pinned SHA-256 digest for every downloaded source archive, PHAR, installer, PECL package, OpenSSL patch, and acme.sh release; invalid cached artifacts are deleted and fetched again.
- Remove `wget --no-check-certificate`, floating Composer/WP-CLI/acme.sh installers, acme.sh auto-update, and the floating Docker installer URL. acme.sh and Docker installer updates now use repository-pinned upstream artifacts.
- Remove unused source-version declarations for libraries that are actually supplied by Ubuntu packages, avoiding a false reproducibility claim.
- Build Nginx with OpenSSL 3.5.9 plus the five official 3.5-branch fixes from the 2026-11-10 advisory while the announced 3.5.10 release artifact is unavailable.
- Enforce PHP's upstream `session.upload_progress.enabled=0` mitigation for CVE-2026-115560 on fresh installs and upgrades, include that setting in upgrade drift detection, and stop publishing the installer-generated `phpinfo.php`.
- Stop installing phpMyAdmin 5.2.3 because it has publicly disclosed vulnerabilities and no fixed release; upgrade inventory now schedules protected backup and removal of legacy web-served copies.

### Component Updates

- Nginx 1.30.4 → 1.30.6
- OpenSSL 3.5.7 → 3.5.9 plus official 2026-11-10 security patch set
- MySQL 8.4.11 → 8.4.13 LTS
- PHP 8.4.25 → 8.4.27
- Redis 8.10.1 → 8.10.3
- Memcached 1.6.33 → 1.6.45
- jemalloc 5.3.1 → 5.4.0
- Swoole 6.2.2 → 6.2.5
- Pin Composer 2.11.2, WP-CLI 2.12.0, and acme.sh 3.1.6.

### Upgrade Management

- Add `lnmp upgrade plan` for a read-only runtime-versus-target inventory, including the embedded OpenSSL security patch-set marker.
- Add `lnmp upgrade apply <component...|outdated>` for selected compilation/deployment of Nginx, PHP, database binaries, optional services, PECL extensions, and operator tools; retain `phpmyadmin` only as a legacy-removal target.
- Rebuild every installed PECL extension after a PHP upgrade; validate changed services and restore saved binaries/prefixes on deployment failure.
- Create a compressed logical database backup before a database binary upgrade; retain core rollback copies under `/var/backups/lnmp/` and the previous database prefix beside the live prefix. Database metadata migrations can be one-way, so the logical dump remains the authoritative recovery path.
- Refuse implicit optional-component installation and version downgrades, serialize apply runs with a process lock, and return exit `64` for an empty selection.

## v1.6.2 — 2026-09-25

### Bug Fixes

- Fix optional Redis 8.10 standalone service startup by disabling baked Redis Stack module `loadmodule ./modules/...` directives for the project's core-only Redis install path.
- Correct the README firewall default to match the shipped `Firewall='iptables'` configuration.

## v1.6.1 — 2026-09-07

### Bug Fixes

- Strengthen `lnmp`, `vhost`, `ssl`, and `db` help output with agent/CI rules, required arguments, validation allowlists, safe secret handling, SSL preconditions, examples, and exit-code meanings.
- Add explicit `--help` / `-h` handling for top-level and subcommand-specific help paths so automation can inspect command contracts without triggering side effects.

## v1.6 — 2026-09-07

### New Features

- **Agent-safe non-interactive tool mode** — `lnmp --yes` / `-y`, `LNMP_ASSUME_YES=1`, `NONINTERACTIVE=1`, or `Auto_Install='y'` now force `vhost`, `ssl`, and `db` subcommands to fail fast instead of blocking on prompts.
- **Automation operating contract** — Added `AGENTS.md` with required arguments, sysexits return codes, SSL issuance preconditions, and canonical non-interactive recipes.
- **Unattended acme.sh registration email** — `ACME_EMAIL` or `Acme_Email` can supply the optional Let's Encrypt account email without a prompt.

### Component Updates

- MySQL 8.4.9 → 8.4.11 LTS (generic Linux binary updated to the current official glibc 2.28 build)

### Bug Fixes

- Validate domains, aliases, rewrite rule names, webroot paths, and database identifiers before writing root-owned Nginx configs or running root database SQL.
- Build acme.sh domain arguments as an array so domain input cannot be word-split into extra acme.sh options.
- Return sysexits-style codes for missing automation inputs and transient certificate issuance failures.
- Preserve interactive prompts for optional SSL vhost/redirect updates while defaulting safely in non-interactive runs.
- Stop echoing newly supplied database user passwords to automation logs.
- Avoid exposing the configured MySQL root password in `mysql` / `mysqldump` process arguments by using a temporary 0600 defaults file.

## v1.5 — 2026-09-07

### New Features

- **`lnmp addons` subcommand** — Manage PHP extensions and optional Redis/Memcached services through the installed `lnmp` command.
- **PECL IMAP support for PHP 8.4** — IMAP is now installed as a PECL extension. Existing `Enable_PHP_Imap='y'` overrides are treated as a compatibility alias and queue the `imap` PECL extension during full installs.
- **Memcached systemd service** — `lnmp addons install memcached-server` now installs, enables, and starts a localhost-only Memcached service instead of only installing the binary.

### Component Updates

- PHP 8.4.24 → 8.4.25 (bug fix)

### Bug Fixes

- Add the missing `--with-imap=/usr` configure flag required to build the PECL IMAP extension against Ubuntu's c-client package.
- Install `libsasl2-dev` before compiling PHP with LDAP SASL support enabled by default.
- Make addon dependency installs wait for apt/dpkg locks and fail fast on package installation errors.
- Make the Vim mouse override survive Ubuntu's later `defaults.vim` loading while preserving Vim defaults.

## v1.4 — 2026-09-04

### New Features

- **`lnmp firewall` subcommand** — Manage the firewall after installation without editing config files. Supports `status` (show type, state, open ports), `on` / `off` (enable/disable with default rules), `allow <port>` / `deny <port>` (open/close a port), and `list` (full rule listing). IPv4 and IPv6 rules are managed together, changes are persisted automatically, and operations are idempotent (already-active or already-allowed states are warnings, not errors).
- **iptables firewall enabled by default** — New installs automatically configure iptables to allow SSH, HTTP, and HTTPS while denying all other inbound traffic, instead of leaving the server exposed. Override with `Firewall='n'` (disable) or `Firewall='ufw'` in `lnmp.conf.local`.
- **IPv6 firewall rules** — Firewall setup now applies matching rules for IPv6 alongside IPv4.
- **Ubuntu 26.04 LTS support** — Ubuntu 26.04 is now a supported target with correct defaults. On 26.04 the database engine defaults to MariaDB (Oracle's MySQL 8.4 binary tools require libraries not available on 26.04).

### Component Updates

All component versions bumped to latest stable; every download URL verified reachable (HTTP 200).

- Nginx 1.30.3 → 1.30.4
- PHP 8.4.22 → 8.4.24 (security)
- MariaDB 11.4.5 → 11.4.13 (LTS)
- Redis 7.4.2 → 8.10.1 (core-only build)
- curl 8.12.1 → 8.21.0 (security)
- PCRE2 10.44 → 10.47
- jemalloc 5.3.0 → 5.3.1
- libzip 1.11.2 → 1.11.4
- Swoole 6.2.1 → 6.2.2
- memcached extension 3.3.0 → 3.4.0
- phpMyAdmin 5.2.2 → 5.2.3
- ImageMagick 7.1.2-25 → 7.1.2-30 (download URL moved to GitHub releases; old URL returned 404)
- freetype 2.13.3 → 2.14.3 (switched to mirror URL; main host returned 502)

### Bug Fixes

- **SSL / acme.sh multi-domain issuance** — Fix several problems in the SSL flow: the "add more domains" prompt was unreachable, `acme.sh --issue` returning exit 2 (certificate already exists) was wrongly treated as a fatal error, non-interactive (piped) runs crashed on read prompts (now auto-applies the SSL vhost and HTTP→HTTPS redirect), and the HTTP→HTTPS redirect was inserted at every `index` line instead of only the first `server` block.
- **vhost SSL argument quoting** — Multi-domain SSL arguments are now passed via a bash array, preventing literal quotes from being forwarded to acme.sh (which previously caused a `400 Request payload did not parse as JSON` from Let's Encrypt).
- **acme.sh IDN false positive** — Added the `idn` command to base dependencies so acme.sh no longer fails certificate issuance for domains containing hyphens.
- **pipefail-safe extension checks** — Replaced `grep -q` with `grep >/dev/null` in the `php -m` extension checks. Under `set -o pipefail`, `grep -q` could close the pipe early and trigger a SIGPIPE (exit 141) in the producer, causing loaded extensions to be misreported as missing.
- Install PCRE2 headers required to compile Nginx.
- Install ICU headers required to build the PHP `intl` extension.
- Fix apt update and package install ordering on Ubuntu 26.04.
- Harden installer summary probes against errors during the final report.

### Other Changes

- OPcache JIT is now disabled by default (`opcache.jit` and `opcache.jit_buffer_size` left commented) because it can trigger runtime bugs on some workloads and extension combinations. Enable manually after validating your workload.
- Modern Nginx MIME types installed by default (adds `.mjs`, `.webmanifest`, `.wasm`, source maps, JSON-LD, modern images, fonts, audio, and video).
- Optional IPv6 `listen` directives left commented in the default server block.

## v1.3 — 2026-04-11

### New Features

- **`--resume` flag** — Continue installation after failure without starting over. Completed steps (nginx/mysql/php/tools) are tracked and skipped on resume.
- **Pre-flight environment conflict detection** — Scans `/usr/local` for libraries that conflict with apt-installed packages (iconv, libssl, libxml2, libcurl, etc.). Auto-backup and removal in `--auto` mode, interactive prompt otherwise.
- **Hardened compile paths** — `PKG_CONFIG_PATH` explicitly set to system paths before PHP/Nginx configure to prevent `/usr/local` contamination.

### Bug Fixes

- Fix iconv detection: scan both header (`iconv.h`) and library (`libiconv.so`) separately since they have different names.
- Fix WP-CLI install failure when `/usr/local/bin/wp` is a broken symlink.
- Fix service start failure (e.g. port conflict) aborting the entire installation — now logs warning and continues.
- Fix vhost list missing column headers.
