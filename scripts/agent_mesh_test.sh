#!/usr/bin/env bash
set -euo pipefail

# `swift test` can fail if PATH prefers non-Apple toolchains (for example Conda's `ld`).
# Force XcodeDefault toolchain binaries first, then system bins.
TOOLCHAIN_SWIFT="$(xcrun --toolchain XcodeDefault --find swift)"
TOOLCHAIN_BIN="$(dirname "${TOOLCHAIN_SWIFT}")"
export PATH="${TOOLCHAIN_BIN}:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

exec xcrun --toolchain XcodeDefault swift test "$@"

