#!/usr/bin/env bash
# publish-codedb.sh — Build codedb from local source and publish as a GitHub Release
# Builds from the repo's own source tree (includes custom C#/F# parsers).
#
# Builds for ALL supported platforms:
#   - linux-x86_64, linux-aarch64
#   - darwin-x86_64, darwin-aarch64
#   - windows-x86_64, windows-aarch64
#
# Usage:
#   bash scripts/publish-codedb.sh              # uses latest git tag
#   bash scripts/publish-codedb.sh v0.2.6000    # explicit tag
#   PLATFORMS="linux-x86_64 darwin-aarch64" bash scripts/publish-codedb.sh  # subset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_DIR}/.build"
RELEASE_DIR="${REPO_DIR}/.release"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
FORK_REPO="jwvolschenk_crdc/codedb_custom"

# All supported cross-compilation targets
ALL_TARGETS=(
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-macos"
    "aarch64-macos"
    "x86_64-windows"
    "aarch64-windows"
)

# ── Colors ───────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m'
W='\033[1;37m' D='\033[0;90m' N='\033[0m'

ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
info() { printf "  ${D}│${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }
err()  { printf "  ${R}✗${N} %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

# ── Check prerequisites ──────────────────────────────────────────────────
check_prereqs() {
    command -v zig >/dev/null 2>&1     || die "Zig not found. Install: https://ziglang.org/download/"
    command -v git >/dev/null 2>&1     || die "git not found"
    command -v curl >/dev/null 2>&1    || die "curl not found"
    command -v gh >/dev/null 2>&1      || die "gh CLI not found. Install: https://cli.github.com/"
    gh auth status >/dev/null 2>&1     || die "gh not authenticated. Run: gh auth login"
}

# ── Map Zig target to artifact name ──────────────────────────────────────
# Zig target format:  arch-os    (e.g. x86_64-linux, aarch64-macos)
# Artifact name:      codedb-{arch}-{os}[.exe]
target_to_artifact() {
    local zig_target="$1"
    local arch="${zig_target%%-*}"
    local os_part="${zig_target#*-}"

    # Map zig os names to our naming
    case "$os_part" in
        macos)  os_part="darwin" ;;
        linux)  os_part="linux" ;;
        windows) os_part="windows" ;;
    esac

    local name="codedb-${arch}-${os_part}"
    if [[ "$os_part" == "windows" ]]; then
        name="${name}.exe"
    fi
    echo "$name"
}

# ── Build from local source ──────────────────────────────────────────────
build() {
    local zig_target="$1"

    # Verify source files exist
    [ -f "${REPO_DIR}/build.zig" ] || die "build.zig not found in ${REPO_DIR}"
    [ -f "${REPO_DIR}/src/csharp_parser.zig" ] || die "C# parser not found — source tree may be incomplete"

    info "Building from local source (${zig_target}, ReleaseFast)..."
    (cd "$REPO_DIR" && zig build -Doptimize=ReleaseFast -Dtarget="$zig_target")

    # Zig outputs to zig-out/bin/codedb (or codedb.exe on Windows)
    local built_binary="${REPO_DIR}/zig-out/bin/codedb"
    if [[ "$zig_target" == *"-windows" ]]; then
        built_binary="${built_binary}.exe"
    fi

    if [ ! -f "$built_binary" ]; then
        die "Build failed for ${zig_target} — binary not found at ${built_binary}"
    fi

    ok "Build complete: ${zig_target}"
}

# ── Package ──────────────────────────────────────────────────────────────
package() {
    local zig_target="$1"
    local artifact_name
    artifact_name="$(target_to_artifact "$zig_target")"

    mkdir -p "$RELEASE_DIR"

    local built_binary="${REPO_DIR}/zig-out/bin/codedb"
    if [[ "$zig_target" == *"-windows" ]]; then
        built_binary="${built_binary}.exe"
    fi

    cp "$built_binary" "${RELEASE_DIR}/${artifact_name}"
    chmod +x "${RELEASE_DIR}/${artifact_name}"

    ok "Packaged: ${artifact_name} ($(du -h "${RELEASE_DIR}/${artifact_name}" | cut -f1))"
}

# ── Determine version tag ────────────────────────────────────────────────
get_version_tag() {
    # Use explicit arg if provided, otherwise use git describe
    local tag="${1:-}"
    if [ -z "$tag" ]; then
        tag="$(cd "$REPO_DIR" && git describe --tags --abbrev=7 2>/dev/null || true)"
    fi
    if [ -z "$tag" ]; then
        tag="v$(cd "$REPO_DIR" && git rev-parse --short HEAD)"
    fi
    echo "$tag"
}

# ── Resolve which targets to build ───────────────────────────────────────
resolve_targets() {
    # If PLATFORMS env var is set, use it (space-separated friendly names)
    if [ -n "${PLATFORMS:-}" ]; then
        echo "$PLATFORMS"
        return
    fi

    # If --target flag passed, build only that one
    if [ -n "${SINGLE_TARGET:-}" ]; then
        echo "$SINGLE_TARGET"
        return
    fi

    # Default: build all
    echo "${ALL_TARGETS[*]}"
}

# ── Publish ──────────────────────────────────────────────────────────────
publish() {
    local tag="$1"
    local release_dir="$RELEASE_DIR"

    info "Publishing release ${tag} to ${FORK_REPO}..."

    # Gather all artifacts + checksums
    local artifacts=()
    for f in "${release_dir}"/codedb-*; do
        [ -f "$f" ] && artifacts+=("$f")
    done
    [ -f "${release_dir}/checksums.sha256" ] && artifacts+=("${release_dir}/checksums.sha256")

    if [ ${#artifacts[@]} -eq 0 ]; then
        die "No artifacts found in ${release_dir}"
    fi

    # Create release if it doesn't exist
    if ! gh release view "$tag" --repo "$FORK_REPO" >/dev/null 2>&1; then
        gh release create "$tag" \
            --repo "$FORK_REPO" \
            --title "codedb ${tag}" \
            --generate-notes \
            "${artifacts[@]}"
        ok "Release created: ${tag}"
    else
        gh release upload "$tag" \
            "${artifacts[@]}" \
            --clobber --repo "$FORK_REPO"
        ok "Assets uploaded to existing release: ${tag}"
    fi

    echo ""
    printf "  ${G}Release URL:${N}\n"
    printf "  ${C}https://github.com/${FORK_REPO}/releases/tag/${tag}${N}\n"
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
    echo ""
    printf "  ${W}codedb publish${N} ${D}build + release (multi-platform)${N}\n"
    printf "  ${D}From local source (includes C#/F# parsers)${N}\n"
    echo ""

    check_prereqs

    local tag
    tag="$(get_version_tag "${1:-}")"
    info "Version tag: ${tag}"

    # Clean release dir for fresh build
    rm -rf "$RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"

    # Resolve target list
    local targets_str
    targets_str="$(resolve_targets)"
    read -ra targets <<< "$targets_str"

    echo ""
    printf "  ${W}Building ${#targets[@]} targets:${N}\n"
    for t in "${targets[@]}"; do
        printf "    ${D}•${N} %s → %s\n" "$t" "$(target_to_artifact "$t")"
    done
    echo ""

    # Build and package each target
    local built=0 failed=0
    for target in "${targets[@]}"; do
        printf "\n  ${W}[${built}+${failed}/${#targets[@]}]${N} Building ${target}...\n"
        if build "$target" && package "$target"; then
            built=$((built + 1))
        else
            failed=$((failed + 1))
            warn "FAILED: ${target} (skipping)"
        fi
    done

    # Update checksums (all artifacts together)
    (cd "$RELEASE_DIR" && sha256sum codedb-* 2>/dev/null | sort > checksums.sha256)

    echo ""
    printf "  ${W}Build summary:${N} ${G}${built} succeeded${N}, ${R}${failed} failed${N}\n"

    if [ "$built" -eq 0 ]; then
        die "No targets built successfully"
    fi

    # List artifacts
    echo ""
    printf "  ${W}Artifacts:${N}\n"
    for f in "${RELEASE_DIR}"/codedb-*; do
        [ -f "$f" ] && printf "    ${D}•${N} %s  ${D}(%s)${N}\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done

    echo ""
    printf "  ${W}Publish to GitHub?${N}\n"
    printf "  ${D}This will upload ${built} binaries to https://github.com/${FORK_REPO}/releases${N}\n"
    read -rp "  Continue? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        publish "$tag"
    else
        printf "\n  ${D}Skipped publish. Artifacts are in ${RELEASE_DIR}/${N}\n"
        printf "  ${D}Upload manually: gh release create <tag> ${RELEASE_DIR}/codedb-*${N}\n"
    fi

    echo ""
}

main "$@"
