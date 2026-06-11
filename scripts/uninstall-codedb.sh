#!/usr/bin/env bash
# uninstall-codedb.sh — Remove codedb binary and MCP registrations from all agents
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────
INSTALL_DIR="${CODEDB_DIR:-$HOME/.local/bin}"

# ── Colors ───────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m'
W='\033[1;37m' D='\033[0;90m' N='\033[0m'

ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
skip() { printf "  ${D}–${N}  %s\n" "$*"; }
info() { printf "  ${D}│${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N}  %s\n" "$*"; }

# ── JSON helper ──────────────────────────────────────────────────────────
remove_from_json() {
    local config_path="$1" server_name="$2"

    if [ ! -f "$config_path" ]; then
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 not found — remove codedb from ${config_path} manually"
        return
    fi

    python3 - "$config_path" "$server_name" << 'PYEOF'
import json, sys, os
config_path, server_name = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
changed = False
for key in ("mcpServers", "servers"):
    if key in data and server_name in data[key]:
        del data[key][server_name]
        changed = True
if changed:
    with open(config_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"removed from {config_path}")
PYEOF
}

# ── Remove from Hermes ───────────────────────────────────────────────────
unregister_hermes() {
    local config="$HOME/.hermes/config.yaml"
    if [ ! -f "$config" ]; then
        skip "Hermes          (not installed)"
        return
    fi
    if ! grep -q 'codedb' "$config" 2>/dev/null; then
        skip "Hermes          (not registered)"
        return
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$config" << 'PYEOF'
import sys
config_path = sys.argv[1]
with open(config_path) as f:
    lines = f.readlines()

new_lines = []
in_codedb = False
for line in lines:
    stripped = line.strip()
    if stripped == 'codedb:' and not line.startswith('    '):
        # Top-level under mcp_servers (2-space indent)
        in_codedb = True
        continue
    if in_codedb:
        # Skip indented lines belonging to codedb block
        if line.startswith('    ') or stripped == '':
            continue
        in_codedb = False
    new_lines.append(line)

with open(config_path, 'w') as f:
    f.writelines(new_lines)
PYEOF
    else
        # Fallback: sed (may corrupt YAML)
        sed -i '/^  codedb:/,/^[^ ]/{ /^  codedb:/d; /^[ ]/d; }' "$config" 2>/dev/null || true
    fi
    ok "Hermes          → ${config}"
}

# ── Remove from Copilot ──────────────────────────────────────────────────
unregister_copilot() {
    local global_config="$HOME/.copilot/mcp-config.json"
    if [ -f "$global_config" ]; then
        remove_from_json "$global_config" "codedb"
        ok "GitHub Copilot  → ${global_config}"
    else
        skip "GitHub Copilot  (not installed)"
    fi

    # Workspace-level configs
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        local ws_config="$(git rev-parse --show-toplevel)/.vscode/mcp.json"
        if [ -f "$ws_config" ]; then
            remove_from_json "$ws_config" "codedb"
            ok "GitHub Copilot  → ${ws_config}"
        fi
    fi
}

# ── Remove from Claude ───────────────────────────────────────────────────
unregister_claude() {
    local config="$HOME/.claude.json"
    if [ -f "$config" ]; then
        remove_from_json "$config" "codedb"
        ok "Claude Code     → ~/.claude.json"
    else
        skip "Claude Code     (not installed)"
    fi
}

# ── Remove from Codex ────────────────────────────────────────────────────
unregister_codex() {
    local config="$HOME/.codex/config.toml"
    if [ ! -f "$config" ]; then
        skip "Codex           (not installed)"
        return
    fi
    if ! grep -q '\[mcp_servers\.codedb\]' "$config" 2>/dev/null; then
        skip "Codex           (not registered)"
        return
    fi
    # Remove the [mcp_servers.codedb] block (3 lines after the header)
    sed -i '/^\[mcp_servers\.codedb\]/,/^\[/{ /^\[mcp_servers\.codedb\]/d; /^\[/!d; }' "$config"
    ok "Codex           → ${config}"
}

# ── Remove from Gemini ───────────────────────────────────────────────────
unregister_gemini() {
    local config="$HOME/.gemini/settings.json"
    if [ -f "$config" ]; then
        remove_from_json "$config" "codedb"
        ok "Gemini CLI      → ~/.gemini/settings.json"
    else
        skip "Gemini CLI      (not installed)"
    fi
}

# ── Remove from Cursor ───────────────────────────────────────────────────
unregister_cursor() {
    local config="$HOME/.cursor/mcp.json"
    if [ -f "$config" ]; then
        remove_from_json "$config" "codedb"
        ok "Cursor          → ~/.cursor/mcp.json"
    else
        skip "Cursor          (not installed)"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
    echo ""
    printf "  ${W}codedb uninstall${N}\n"
    echo ""

    # 1. Kill running processes
    if pgrep -f 'codedb.*mcp' >/dev/null 2>&1; then
        pkill -f 'codedb.*mcp' 2>/dev/null || true
        sleep 1
        info "Stopped running codedb processes"
    fi

    # 2. Remove binary
    if [ -f "${INSTALL_DIR}/codedb" ]; then
        rm -f "${INSTALL_DIR}/codedb"
        ok "Removed binary  → ${INSTALL_DIR}/codedb"
    else
        skip "Binary          (not found at ${INSTALL_DIR}/codedb)"
    fi

    # Also remove legacy location if it exists
    if [ -f "$HOME/bin/codedb" ] && [ ! -L "$HOME/bin/codedb" ]; then
        rm -f "$HOME/bin/codedb"
        ok "Removed binary  → ~/bin/codedb"
    elif [ -L "$HOME/bin/codedb" ]; then
        rm -f "$HOME/bin/codedb"
        ok "Removed symlink → ~/bin/codedb"
    fi

    # 3. Remove cached indexes
    if [ -d "$HOME/.codedb" ]; then
        rm -rf "$HOME/.codedb"
        ok "Removed caches  → ~/.codedb/"
    fi

    # 4. Remove MCP registrations
    echo ""
    printf "  ${W}Removing MCP registrations${N}\n"
    echo ""

    unregister_hermes
    unregister_copilot
    unregister_claude
    unregister_codex
    unregister_gemini
    unregister_cursor

    # 5. Done
    echo ""
    printf "  ${G}Done!${N} codedb has been removed.\n"
    printf "  ${D}Restart your agent sessions for changes to take effect.${N}\n"
    echo ""
}

main "$@"
