#!/usr/bin/env bash
# lib/common.sh — Common utility functions

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

cur_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="/root/lnmp-install.log"

log_info()  { echo -e "${CYAN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; echo -e "${RED}[ERROR]${NC} $*" >> "$LOG_FILE" 2>/dev/null || true; }
die()       { log_err "$*"; _die_resume_hint; exit 1; }

###############################################################################
# Non-interactive / automation support
#
# These helpers let every lnmp subcommand run cleanly under an AI agent, CI,
# cloud-init or `ssh host 'cmd'` (no TTY) while behaving exactly as before for
# a human at an interactive terminal.
#
# Standard exit codes follow sysexits(3) so callers (agents, CI) can branch on
# failure type instead of parsing text:
#   EX_USAGE (64)        missing/invalid argument in non-interactive mode
#   EX_UNAVAILABLE (69)  a required dependency/service is missing
#   EX_TEMPFAIL (75)     transient failure, safe to retry later
###############################################################################

# Exported so sourcing scripts (and the subcommands they spawn) share the codes.
export EX_OK=0
export EX_USAGE=64
export EX_UNAVAILABLE=69
export EX_TEMPFAIL=75

# is_interactive — true only when it is safe to prompt the user.
# Interactive requires BOTH:
#   1. stdin is a real terminal ([[ -t 0 ]])
#   2. the operator has NOT requested non-interactive mode
#
# Non-interactive is forced when any of these is set:
#   NONINTERACTIVE=1 | LNMP_ASSUME_YES=1 | Auto_Install='y' (from lnmp.conf)
#
# Rationale (verified): [[ -t 0 ]] alone is unreliable for CI/agent runs where
# stdin may be neither a TTY nor a pipe; an explicit flag/env is the robust
# complement. See sysexits(3) and common shell automation guidance.
is_interactive() {
    [[ "${NONINTERACTIVE:-}" = "1" ]] && return 1
    [[ "${LNMP_ASSUME_YES:-}" = "1" ]] && return 1
    [[ "${Auto_Install:-n}" =~ ^[Yy]$ ]] && return 1
    [[ -t 0 ]]
}

# die_code <exit_code> <message...> — like die() but with an explicit sysexits code.
die_code() {
    local code="$1"; shift
    log_err "$*"
    _die_resume_hint
    exit "$code"
}

# validate_domain <domain> — accept DNS names safe for nginx/acme file/config use.
# HTTP-01 webroot issuance does not support wildcard names, so only ordinary
# ASCII/punycode labels are accepted.
validate_domain() {
    local domain="$1"
    [[ -n "$domain" ]] || die_code "$EX_USAGE" "Domain cannot be empty."
    [[ ${#domain} -le 253 ]] || die_code "$EX_USAGE" "Invalid domain '${domain}': too long."
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        || die_code "$EX_USAGE" "Invalid domain '${domain}'. Use an ASCII/punycode DNS name."
}

validate_domain_list() {
    local domain
    for domain in "$@"; do
        validate_domain "$domain"
    done
}

validate_mysql_name() {
    local kind="$1" value="$2"
    [[ "$value" =~ ^[A-Za-z0-9_]{1,64}$ ]] \
        || die_code "$EX_USAGE" "Invalid ${kind} '${value}'. Use 1-64 characters: letters, numbers, underscore."
}

sql_escape_string() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\'/\'\'}
    printf '%s' "$value"
}

validate_abs_path() {
    local kind="$1" path="$2"
    [[ "$path" =~ ^/[A-Za-z0-9._~+@%/=-]+$ ]] \
        || die_code "$EX_USAGE" "Invalid ${kind} '${path}'. Use an absolute path without spaces or shell/nginx metacharacters."
}

# Print resume hint when installation fails
_die_resume_hint() {
    [[ -n "${INSTALL_TARGET:-}" ]] || return 0
    [[ -f "${_PROGRESS_FILE:-}" ]] || return 0
    echo ""
    log_info "After fixing the issue, resume with:"
    echo "  sudo ./install.sh --resume ${INSTALL_TARGET}"
}

# Wait for apt/dpkg lock before running apt commands
wait_apt_lock() {
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        log_info "Waiting for apt lock..."
        sleep 3
    done
}

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

# Download file with retry, optional sha256 verification
# Usage: download_src "Name" "URL" ["sha256"]
download_src() {
    local name="$1" url="$2" sha256="${3:-}"
    local filename dest
    filename="$(basename "$url")"
    dest="${cur_dir}/src/${filename}"

    if [[ -f "$dest" ]]; then
        if [[ -n "$sha256" ]] && verify_sha256 "$dest" "$sha256"; then
            log_info "${name}: ${filename} [cached]"
            return 0
        elif [[ -z "$sha256" ]]; then
            log_info "${name}: ${filename} [cached]"
            return 0
        fi
        rm -f "$dest"
    fi

    log_info "Downloading ${name} from ${url} ..."
    local i
    for i in 1 2 3; do
        if wget -c --progress=dot:giga --prefer-family=IPv4 --no-check-certificate -T 120 -t 1 -O "$dest" "$url" 2>&1 | tee -a "$LOG_FILE"; then
            break
        fi
        log_warn "Retry ${i}/3 for ${name}..."
        sleep 2
    done

    [[ -f "$dest" && -s "$dest" ]] || die "Failed to download ${name}"

    if [[ -n "$sha256" ]]; then
        verify_sha256 "$dest" "$sha256" || die "Checksum mismatch: ${name}"
    fi
    log_ok "${name} downloaded."
}

verify_sha256() {
    local file="$1" expected="$2"
    echo "${expected}  ${file}" | sha256sum -c --quiet 2>/dev/null
}

# Extract tarball and cd into it
# Usage: tar_cd "filename.tar.gz" ["expected_dir_name"]
tar_cd() {
    local file="$1" dir="${2:-}"
    local src_dir="${cur_dir}/src"

    cd "$src_dir" || die "Cannot cd to ${src_dir}"

    [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"

    case "$file" in
        *.tar.gz|*.tgz)   tar zxf "$file" ;;
        *.tar.bz2)        tar jxf "$file" ;;
        *.tar.xz)         tar Jxf "$file" ;;
        *)                 die "Unknown archive format: $file" ;;
    esac

    if [[ -n "$dir" ]]; then
        cd "$dir" || die "Cannot cd to ${dir}"
    else
        # Auto-detect extracted directory
        local extracted
        extracted="$(tar tf "$file" 2>/dev/null | head -1 | cut -d/ -f1)"
        if [[ -n "$extracted" && -d "$extracted" ]]; then
            cd "$extracted" || die "Cannot cd to extracted directory: ${extracted}"
        else
            die "Cannot cd to extracted directory: ${extracted:-unknown}"
        fi
    fi
}

# Compile and install with parallel make
make_install() {
    local jobs
    jobs=$(nproc 2>/dev/null || echo 1)

    make -j"$jobs" 2>&1 | tee -a "$LOG_FILE"
    local make_rc=${PIPESTATUS[0]}
    [[ $make_rc -eq 0 ]] || die "make failed (exit code: $make_rc)"

    make install 2>&1 | tee -a "$LOG_FILE"
    local install_rc=${PIPESTATUS[0]}
    [[ $install_rc -eq 0 ]] || die "make install failed (exit code: $install_rc)"
}

# Create symlink if not exists
create_lib_link() {
    if [[ -d /usr/lib64 ]] && [[ ! -L /usr/lib64 ]]; then
        [[ -e /usr/lib64/libpcre.so ]] || ln -sf /usr/local/lib/libpcre.so.1 /usr/lib64/ 2>/dev/null
    fi
    ldconfig
}

# Print banner
print_banner() {
    echo "+---------------------------------------------------+"
    echo "|              LNMP Stack Installer                  |"
    echo "+---------------------------------------------------+"
}
