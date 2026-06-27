#!/usr/bin/env bash
# publish-codedb.sh — Build codedb from local source and publish as a GitHub Release
# Interactive version prompt — suggests the next semver based on the latest tag,
# then creates/pushes the tag, builds cross-platform binaries, and uploads to
# GitHub Releases.
#
# Builds from the repo's own source tree (includes custom C#/F# parsers).
#
# Builds for ALL supported platforms:
#   - linux-x86_64, linux-aarch64
#   - darwin-x86_64, darwin-aarch64
#   - windows-x86_64, windows-aarch64
#
# Usage:
#   bash scripts/publish-codedb.sh              # interactive version prompt
#   bash scripts/publish-codedb.sh v0.2.6000    # explicit tag (skips prompt)
#   PLATFORMS="linux-x86_64 darwin-aarch64" bash scripts/publish-codedb.sh  # subset
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_DIR}/.build"
RELEASE_DIR="${REPO_DIR}/.release"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
FORK_REPO="jwvolschenk/codedb"

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

# ── Ensure gh can push to the target repo ─────────────────────────────────
# If the active account can't push to the repo, list available accounts and
# let the user switch before we start building.
ensure_repo_access() {
    # Already good?
    if [[ "$(gh api "repos/${FORK_REPO}" --jq '.permissions.push' 2>/dev/null || echo false)" == "true" ]]; then
        return 0
    fi

    local active_user
    active_user="$(gh api user --jq '.login' 2>/dev/null || echo 'unknown')"

    echo ""
    warn "Active gh account '${active_user}' cannot push to ${FORK_REPO}"
    info "Switch to an account with release/tag push permissions before publishing."
    echo ""

    # List all configured accounts
    local accounts=()
    while IFS= read -r line; do
        [ -n "$line" ] && accounts+=("$line")
    done < <(gh auth status 2>&1 | grep -oE 'Logged in to github\.com account [^ ]+' | awk '{print $NF}')

    if [ ${#accounts[@]} -eq 0 ]; then
        die "No gh accounts found. Run: gh auth login"
    fi

    printf "  ${W}Available gh accounts:${N}\n"
    printf "\n"
    for i in "${!accounts[@]}"; do
        local marker=""
        [[ "${accounts[$i]}" == "$active_user" ]] && marker=" ${D}(current)${N}"
        printf "    ${C}%d)${N} %s%b\n" "$((i+1))" "${accounts[$i]}" "$marker"
    done
    printf "\n"
    printf "  ${W}Switch to which account?${N} "
    read -r choice

    [ -n "$choice" ] || die "Selection required"

    local idx=$((choice - 1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#accounts[@]}" ]; then
        die "Invalid selection"
    fi

    local chosen="${accounts[$idx]}"
    if [ "$chosen" == "$active_user" ]; then
        die "Already using '${chosen}' — it cannot push to ${FORK_REPO}"
    fi

    info "Switching to '${chosen}'..."
    gh auth switch --user "$chosen" >/dev/null 2>&1 || die "Failed to switch to '${chosen}'"
    ok "Switched to '${chosen}'"

    # Verify push access with the new account
    if [[ "$(gh api "repos/${FORK_REPO}" --jq '.permissions.push' 2>/dev/null || echo false)" != "true" ]]; then
        die "Account '${chosen}' still cannot push to ${FORK_REPO}. Check repo permissions."
    fi
    ok "Repo push access confirmed: ${FORK_REPO}"
}

# ── Check prerequisites ──────────────────────────────────────────────────
check_prereqs() {
    command -v zig >/dev/null 2>&1     || die "Zig not found. Install: https://ziglang.org/download/"
    command -v git >/dev/null 2>&1     || die "git not found"
    command -v curl >/dev/null 2>&1    || die "curl not found"
    command -v gh >/dev/null 2>&1      || die "gh CLI not found. Install: https://cli.github.com/"
    gh auth status >/dev/null 2>&1     || die "gh not authenticated. Run: gh auth login"
    ensure_repo_access
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

# ── Bump semver ──────────────────────────────────────────────────────────
# Given v1.2.3, suggests: patch=v1.2.4, minor=v1.3.0, major=v2.0.0
bump_version() {
    local current="$1"
    local part="$2"
    # Strip v prefix and any prerelease/build metadata before arithmetic.
    local v="${current#v}"
    v="${v%%[-+]*}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$v"
    case "$part" in
        patch) printf "v%s.%s.%s" "$major" "$minor" "$((patch + 1))" ;;
        minor) printf "v%s.%s.0" "$major" "$((minor + 1))" ;;
        major) printf "v%s.0.0" "$((major + 1))" ;;
    esac
}

# ── Interactive version prompt ───────────────────────────────────────────
# NOTE: prompts go to >&2 so that command substitution $() only captures
# the final version string on stdout.
prompt_version() {
    local latest_tag="$1"

    if [ -z "$latest_tag" ]; then
        printf "  ${W}No existing tags found.${N}\n" >&2
        printf "  Enter version tag (e.g. ${C}v1.0.0${N}): " >&2
        read -r tag
        [ -n "$tag" ] || die "Version tag required"
        echo "$tag"
        return
    fi

    local patch minor major
    patch="$(bump_version "$latest_tag" patch)"
    minor="$(bump_version "$latest_tag" minor)"
    major="$(bump_version "$latest_tag" major)"

    printf "\n" >&2
    printf "  ${W}Current version:${N} ${latest_tag}\n" >&2
    printf "\n" >&2
    printf "  ${W}Select next version:${N}\n" >&2
    printf "    ${C}1)${N} ${patch}  ${D}(patch)${N}\n" >&2
    printf "    ${C}2)${N} ${minor}  ${D}(minor)${N}\n" >&2
    printf "    ${C}3)${N} ${major}  ${D}(major)${N}\n" >&2
    printf "    ${C}4)${N} custom\n" >&2
    printf "\n" >&2
    printf "  Choice [1]: " >&2
    read -r choice
    choice="${choice:-1}"

    case "$choice" in
        1) echo "$patch" ;;
        2) echo "$minor" ;;
        3) echo "$major" ;;
        4)
            printf "  Enter version tag (e.g. ${C}v2.0.0-rc1${N}): " >&2
            read -r tag
            [ -n "$tag" ] || die "Version tag required"
            echo "$tag"
            ;;
        *) echo "$patch" ;;
    esac
}

# ── Get latest git tag ───────────────────────────────────────────────────
get_latest_tag() {
    cd "$REPO_DIR" && git describe --tags --abbrev=0 2>/dev/null || true
}

# ── Inject version into release_info.zig ─────────────────────────────────
inject_version() {
    local tag="$1"
    # Strip v/V prefix
    local semver="${tag#v}"
    semver="${semver#V}"
    local file="${REPO_DIR}/src/release_info.zig"
    [ -f "$file" ] || die "release_info.zig not found"
    printf 'pub const semver = "%s";\n' "$semver" > "$file"
    info "Injected version ${semver} into release_info.zig"
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

    # 1. Determine version tag
    local tag="${1:-}"
    if [ -z "$tag" ]; then
        local latest_tag
        latest_tag="$(get_latest_tag)"
        tag="$(prompt_version "$latest_tag")"
    fi
    info "Version tag: ${tag}"

    # 2. Confirm before proceeding
    echo ""
    printf "  ${W}This will:${N}\n"
    printf "    ${D}1.${N} Create and push git tag ${C}${tag}${N}\n"
    printf "    ${D}2.${N} Build binaries for ${#ALL_TARGETS[@]} platforms\n"
    printf "    ${D}3.${N} Upload to https://github.com/${FORK_REPO}/releases\n"
    echo ""
    printf "  Continue? [y/N] "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { printf "\n  ${D}Aborted.${N}\n\n"; exit 0; }

    # 3. Create and push tag
    echo ""
    info "Creating tag ${tag}..."
    cd "$REPO_DIR"
    git tag -a "$tag" -m "Release ${tag}" 2>/dev/null || {
        warn "Tag ${tag} already exists locally"
    }
    git push origin "$tag" 2>/dev/null || {
        if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
            warn "Tag ${tag} already exists on remote"
        else
            die "Failed to push tag ${tag} to origin"
        fi
    }
    ok "Tag ${tag} pushed"

    # 4. Inject version into source before building
    inject_version "$tag"

    # 5. Clean release dir for fresh build
    rm -rf "$RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"

    # 6. Resolve target list
    local targets_str
    targets_str="$(resolve_targets)"
    read -ra targets <<< "$targets_str"

    echo ""
    printf "  ${W}Building ${#targets[@]} targets:${N}\n"
    for t in "${targets[@]}"; do
        printf "    ${D}•${N} %s → %s\n" "$t" "$(target_to_artifact "$t")"
    done
    echo ""

    # 7. Build and package each target
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
