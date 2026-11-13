#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/detect.sh"
LOG_FILE="${TEST_TMP}/compatibility.log"
INSTALL_TARGET=nginx

detect_os
check_os_support
[[ "$OS_ID" = ubuntu ]]
[[ "$OS_VER" = "${EXPECTED_UBUNTU:?EXPECTED_UBUNTU is required}" ]]
[[ "$ARCH" = x86_64 || "$ARCH" = aarch64 ]]
command -v sort >/dev/null
printf 'ubuntu_compatibility_test: PASS (%s %s, bash %s)\n' "$OS_VER" "$ARCH" "$BASH_VERSION"


set +e
(OS_VER=25.10; OS_CODENAME=questing; check_os_support) >/dev/null 2>&1
unsupported_rc=$?
set -e
[[ "$unsupported_rc" -eq 1 ]]