# Changelog

All notable changes to this project are documented in this file.

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
