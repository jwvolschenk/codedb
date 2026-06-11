#!/usr/bin/env bash
# setup-codedb.sh — Download codedb from our GitHub Release and register with all AI agents
# This is the consumer-facing installer. For building from source, use build-codedb.sh.
#
# Auto-detects platform and downloads the matching binary:
#   linux-x86_64, linux-aarch64, darwin-x86_64, darwin-aarch64, windows-x86_64, windows-aarch64
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jwvolschenk/codedb/main/scripts/setup-codedb.sh | bash
#   bash scripts/setup-codedb.sh
#   CODEDB_VERSION=v0.2.6000 bash scripts/setup-codedb.sh
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────
INSTALL_DIR="${CODEDB_DIR:-$HOME/.local/bin}"
FORK_REPO="jwvolschenk/codedb"

# ── Colors ───────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m'
W='\033[1;37m' D='\033[0;90m' N='\033[0m'

ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
skip() { printf "  ${D}–${N}  %s\n" "$*"; }
info() { printf "  ${D}│${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }
err()  { printf "  ${R}✗${N} %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

# ── Detect platform ──────────────────────────────────────────────────────
# Returns: {arch}-{os} matching publish artifact names
#   e.g. x86_64-linux, aarch64-darwin, x86_64-windows
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin) os="darwin" ;;
        Linux)  os="linux" ;;
        MINGW*_NT*|MSYS_NT*|CYGWIN_NT*)
            echo ""
            printf "  ${Y}Windows detected.${N} Use the PowerShell installer instead:\n\n"
            printf "    ${C}powershell -ExecutionPolicy Bypass -File scripts/setup-codedb.ps1${N}\n\n"
            printf "  ${D}Or from a PowerShell terminal:${N}\n"
            printf "    ${C}irm https://raw.githubusercontent.com/${FORK_REPO}/main/scripts/setup-codedb.ps1 | iex${N}\n\n"
            exit 0
            ;;
        *) die "Unsupported OS: $os" ;;
    esac
    case "$arch" in
        arm64|aarch64)                   arch="aarch64" ;;
        x86_64|amd64|x86-64)            arch="x86_64" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac
    echo "${arch}-${os}"
}

# ── Map platform to artifact filename ────────────────────────────────────
# Platform format:  arch-os        (e.g. x86_64-linux)
# Artifact name:    codedb-{arch}-{os}
platform_to_artifact() {
    local platform="$1"
    echo "codedb-${platform}"
}

# ── Fetch latest version tag from our fork's releases ─────────────────────
# Returns the raw tag name (e.g. "V1.0.2" or "v1.0.1") — case-sensitive.
fetch_latest_version() {
    local tag=""
    # Unauthenticated API (works for public repos)
    tag="$(curl -fsSL -A 'codedb-setup' \
        "https://api.github.com/repos/${FORK_REPO}/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name"\s*:\s*"[^"]*"' \
        | cut -d'"' -f4)" || true
    printf '%s' "$tag"
}

# Strip v/V prefix for display
strip_version_prefix() {
    printf '%s' "$1" | sed 's/^[vV]//'
}

# ── Download binary ──────────────────────────────────────────────────────
download_binary() {
    local platform="$1" tag="$2" dest="$3"
    local artifact
    artifact="$(platform_to_artifact "$platform")"
    local tmp="/tmp/codedb-setup.$$"

    info "Downloading ${artifact} ${tag}..."

    # Download via curl (public repo)
    local url="https://github.com/${FORK_REPO}/releases/download/${tag}/${artifact}"
    if ! curl -fsSL -A 'codedb-setup' "$url" -o "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        die "Download failed. Check: https://github.com/${FORK_REPO}/releases"
    fi

    # Verify checksum
    local checksum_text expected_hash
    local checksum_url="https://github.com/${FORK_REPO}/releases/download/${tag}/checksums.sha256"
    checksum_text="$(curl -fsSL -A 'codedb-setup' "$checksum_url" 2>/dev/null || true)"
    expected_hash="$(printf '%s\n' "$checksum_text" | awk "/${artifact}\$/ { print \$1 }")"
    if [ -n "$expected_hash" ]; then
        local actual_hash
        if command -v sha256sum >/dev/null 2>&1; then
            actual_hash="$(sha256sum "$tmp" | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
            actual_hash="$(shasum -a 256 "$tmp" | awk '{print $1}')"
        fi
        if [ -n "${actual_hash:-}" ] && [ "$actual_hash" != "$expected_hash" ]; then
            rm -f "$tmp"
            die "Checksum mismatch — binary may be corrupted"
        fi
        ok "Checksum verified"
    fi

    xattr -c "$tmp" 2>/dev/null || true
    mkdir -p "$(dirname "$dest")"
    mv -f "$tmp" "$dest"
    chmod +x "$dest"
    ok "Installed to ${dest}"
}

# ── Agent Instructions ───────────────────────────────────────────────────
show_agent_instructions() {
    local agent_name="$1"
    local exe_path="$2"

    echo ""
    printf "  ${W}Instructions for ${agent_name}${N}\n"
    echo ""

    case "$(echo "$agent_name" | tr '[:upper:]' '[:lower:]')" in
        hermes)
            printf "  Add the following to ~/.hermes/config.yaml :\n\n"
            printf "  ${C}mcp_servers:${N}\n"
            printf "    ${C}codedb:${N}\n"
            printf "      ${C}command: ${exe_path}${N}\n"
            printf "      ${C}args:${N}\n"
            printf "        ${C}- mcp${N}\n"
            printf "      ${C}enabled: true${N}\n"
            ;;
        copilot)
            printf "  To register globally, add to ~/.copilot/mcp-config.json :\n\n"
            printf "  ${C}{\n    \"mcpServers\": {\n      \"codedb\": {\n        \"command\": \"${exe_path}\",\n        \"args\": [\"mcp\"]\n      }\n    }\n  }${N}\n\n"
            printf "  To register for a specific VS Code workspace, add to .vscode/mcp.json :\n\n"
            printf "  ${C}{\n    \"servers\": {\n      \"codedb\": {\n        \"type\": \"stdio\",\n        \"command\": \"${exe_path}\",\n        \"args\": [\"\${workspaceFolder}\", \"mcp\"]\n      }\n    }\n  }${N}\n"
            ;;
        claude)
            printf "  Add the following to ~/.claude.json :\n\n"
            printf "  ${C}{\n    \"mcpServers\": {\n      \"codedb\": {\n        \"command\": \"${exe_path}\",\n        \"args\": [\"mcp\"]\n      }\n    }\n  }${N}\n"
            ;;
        codex)
            printf "  Add the following to ~/.codex/config.toml :\n\n"
            printf "  ${C}[mcp_servers.codedb]${N}\n"
            printf "  ${C}command = \"${exe_path}\"${N}\n"
            printf "  ${C}args = [\"mcp\"]${N}\n"
            printf "  ${C}startup_timeout_sec = 30${N}\n"
            ;;
        antigravity)
            printf "  Add the following to ~/.gemini/config/mcp_config.json :\n\n"
            printf "  ${C}{\n    \"mcpServers\": {\n      \"codedb\": {\n        \"command\": \"${exe_path}\",\n        \"args\": [\"mcp\"]\n      }\n    }\n  }${N}\n"
            ;;
        gemini)
            printf "  Add the following to ~/.gemini/settings.json :\n\n"
            printf "  ${C}{\n    \"mcpServers\": {\n      \"codedb\": {\n        \"command\": \"${exe_path}\",\n        \"args\": [\"mcp\"]\n      }\n    }\n  }${N}\n"
            ;;
        cursor)
            printf "  Add the following to ~/.cursor/mcp.json :\n\n"
            printf "  ${C}{\n    \"mcpServers\": {\n      \"codedb\": {\n        \"command\": \"${exe_path}\",\n        \"args\": [\"mcp\"]\n      }\n    }\n  }${N}\n"
            ;;
        *)
            err "Unknown agent: $agent_name"
            info "Available agents: Hermes, Copilot, Claude, Codex, Gemini, Antigravity, Cursor"
            ;;
    esac
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
    local agent=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--agent)
                agent="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    echo ""
    printf "  ${W}codedb setup${N}\n"
    echo ""

    # 1. Detect platform
    local platform
    platform="$(detect_platform)"
    info "Platform: ${platform}"

    # 2. Get version tag (raw, case-sensitive — e.g. "V1.0.2")
    local tag="${CODEDB_VERSION:-}"
    if [ -z "$tag" ]; then
        tag="$(fetch_latest_version)"
    fi
    if [ -z "$tag" ]; then
        die "Could not fetch latest version from https://github.com/${FORK_REPO}/releases"
    fi
    info "Version:  $(strip_version_prefix "$tag")"

    # 3. Download and install
    local dest="${INSTALL_DIR}/codedb"
    download_binary "$platform" "$tag" "$dest"

    # 4. Check PATH
    case ":$PATH:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            echo ""
            printf "  ${Y}Note:${N} Add ${INSTALL_DIR} to your PATH:\n"
            printf "    ${C}export PATH=\"${INSTALL_DIR}:\$PATH\"${N}\n"
            printf "    ${D}(add to ~/.bashrc or ~/.zshrc)${N}\n"
            ;;
    esac

    # 5. Agent Instructions
    if [ -n "$agent" ]; then
        show_agent_instructions "$agent" "$dest"
    else
        echo ""
        printf "  ${W}Registration${N}\n"
        printf "  ${D}To get instructions for an AI agent, run with --agent <Name>${N}\n"
        printf "  ${D}Available agents: Hermes, Copilot, Claude, Codex, Gemini, Antigravity, Cursor${N}\n"
    fi

    # 6. Clear snapshot cache
    echo ""
    printf "  ${W}Clearing stale snapshot cache...${N}\n"
    CACHE_DIR="$HOME/.codedb/projects"
    if [ -d "$CACHE_DIR" ]; then
        # Find and count snapshots before deleting for better feedback
        SNAPSHOT_COUNT=$(find "$CACHE_DIR" -name "codedb.snapshot" 2>/dev/null | wc -l | xargs)
        if [ "$SNAPSHOT_COUNT" -gt 0 ]; then
            find "$CACHE_DIR" -name "codedb.snapshot" -delete 2>/dev/null || true
            ok "Deleted $SNAPSHOT_COUNT snapshots from $CACHE_DIR"
        else
            skip "No snapshots found in cache"
        fi
    else
        skip "Cache directory not found ($CACHE_DIR)"
    fi

    # 7. Done
    echo ""
    printf "  ${G}Done!${N}\n"
    printf "  ${D}Binary installed at: ${dest}${N}\n"
    printf "  ${D}Open a project and ask your agent about the codebase.${N}\n"
    echo ""
    printf "  ${D}Update:    bash scripts/setup-codedb.sh${N}\n"
    printf "  ${D}Uninstall: codedb nuke${N}\n"
    echo ""
}

main "$@"

