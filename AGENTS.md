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

Optional values (extra domains, webroot, rewrite, redirect choice) safely fall
back to sensible defaults when not supplied, but supplied values must pass the
allowlists in §1.

---

## 7. Human compatibility (unchanged)

Run any command **without** arguments from a real terminal and it prompts
interactively exactly as before. The non-interactive guards only take effect
when there is no TTY or when `--yes`/`NONINTERACTIVE`/`Auto_Install` is set.
There is a single code path for both modes — no separate "agent mode" to keep
in sync.
