#!/usr/bin/env bash
# build-codedb.sh — Build codedb from local source and install locally
# Builds directly from the repo source tree (includes custom C#/F# parsers).
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_DIR}/.build"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
INSTALL_DIR="${CODEDB_DIR:-$HOME/.local/bin}"

# ── Colors ───────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m'
W='\033[1;37m' D='\033[0;90m' N='\033[0m'

ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
info() { printf "  ${D}│${N} %s\n" "$*"; }
err()  { printf "  ${R}✗${N} %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

# ── Detect platform ──────────────────────────────────────────────────────
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        MINGW*|MSYS*|CYGWIN*)
            echo ""
            printf "\n  ${Y}Windows detected.${N} Use the PowerShell script instead:\n\n"
            printf "    ${C}powershell -File scripts/setup-codedb.ps1${N}\n\n"
            exit 0
            ;;
        *) die "Unsupported OS: $os" ;;
    esac
    case "$arch" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64|amd64)  arch="x86_64" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac
    echo "${arch}-${os}"
}

# ── Check or install Zig ─────────────────────────────────────────────────
ensure_zig() {
    if command -v zig >/dev/null 2>&1; then
        local current
        current="$(zig version 2>/dev/null | head -1)"
        ok "Zig found: ${current}"
        return
    fi

    info "Zig not found — installing Zig ${ZIG_VERSION}..."

    local platform="$1"
    local zig_archive="zig-${platform}-${ZIG_VERSION}.tar.xz"
    local zig_url="https://ziglang.org/download/${ZIG_VERSION}/${zig_archive}"
    local zig_dir="${BUILD_DIR}/zig"

    mkdir -p "$zig_dir"
    info "Downloading ${zig_url}..."
    curl -fsSL "$zig_url" -o "${BUILD_DIR}/${zig_archive}"
    tar -xf "${BUILD_DIR}/${zig_archive}" -C "$zig_dir"
    rm -f "${BUILD_DIR}/${zig_archive}"

    export PATH="${zig_dir}/zig-${platform}-${ZIG_VERSION}:${PATH}"
    ok "Zig installed: $(zig version)"
}

# ── Build from local source ──────────────────────────────────────────────
build() {
    local zig_target="$1"

    info "Building codedb from local source (${zig_target}, ReleaseFast)..."
    info "Source: ${REPO_DIR}"

    # Verify source files exist
    [ -f "${REPO_DIR}/build.zig" ] || die "build.zig not found in ${REPO_DIR}"
    [ -f "${REPO_DIR}/src/csharp_parser.zig" ] || die "C# parser not found — source tree may be incomplete"

    (cd "$REPO_DIR" && zig build -Doptimize=ReleaseFast -Dtarget="$zig_target")

    if [ ! -f "${REPO_DIR}/zig-out/bin/codedb" ]; then
        die "Build failed — binary not found"
    fi

    ok "Build complete"
}

# ── Install ──────────────────────────────────────────────────────────────
install_binary() {
    local binary="$1"
    local dest="${INSTALL_DIR}/codedb"

    mkdir -p "$INSTALL_DIR"
    cp "$binary" "$dest"
    chmod +x "$dest"

    ok "Installed to ${dest}"
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
    echo ""
    printf "  ${W}codedb build${N} ${D}from local source${N}\n"
    printf "  ${D}Includes custom C# and F# parsers${N}\n"
    echo ""

    # 1. Detect platform
    local zig_target
    zig_target="$(detect_platform)"
    info "Target: ${zig_target}"

    # 2. Ensure Zig
    ensure_zig "$zig_target"

    # 3. Build from local source
    build "$zig_target"

    # 4. Install
    echo ""
    install_binary "${REPO_DIR}/zig-out/bin/codedb"

    # 5. Done
    echo ""
    printf "  ${G}Done!${N} codedb built from local source and installed.\n"
    printf "  ${D}Includes: C# parser, F# parser, and all standard parsers.${N}\n"
    printf "  ${D}Next: run bash scripts/setup-codedb.sh to register with your AI agents.${N}\n"
    echo ""
}

main "$@"
