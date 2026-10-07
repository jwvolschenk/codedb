# setup-codedb.ps1 — Download codedb from our GitHub Release and register with all AI agents
# Windows-native installer. No WSL or Git Bash required.
#
# Auto-detects architecture (x86_64 / aarch64), downloads the matching .exe,
# installs to $env:LOCALAPPDATA\codedb\bin, and registers with every detected agent.
#
# Usage:
#   powershell -File scripts/setup-codedb.ps1 --Agent Gemini
#   $env:CODEDB_VERSION = "v0.2.6000"; powershell -File scripts/setup-codedb.ps1

$Version = $env:CODEDB_VERSION
$InstallDir = $env:CODEDB_DIR
$Agent = $null

# Parse arguments manually for better compatibility with different invocation styles
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ($args[$i]) {
        "^-?-(v|Version)$" { $Version = $args[++$i]; break }
        "^-?-(a|Agent)$"   { $Agent = $args[++$i]; break }
        "^-?-(i|InstallDir)$" { $InstallDir = $args[++$i]; break }
    }
}

$ErrorActionPreference = "Stop"

# ── Config ───────────────────────────────────────────────────────────────
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "codedb\bin"
}
$ForkRepo = "jwvolschenk/codedb"

# ── Helpers ──────────────────────────────────────────────────────────────
function Write-Ok($msg)  { Write-Host "  " -NoNewline; Write-Host "$([char]0x2713)" -ForegroundColor Green -NoNewline; Write-Host " $msg" }
function Write-Info($msg) { Write-Host "  " -NoNewline; Write-Host "$([char]0x2502)" -ForegroundColor DarkGray -NoNewline; Write-Host " $msg" }
function Write-Skip($msg) { Write-Host "  " -NoNewline; Write-Host "-" -ForegroundColor DarkGray -NoNewline; Write-Host "  $msg" }
function Write-Warn($msg) { Write-Host "  " -NoNewline; Write-Host "!" -ForegroundColor Yellow -NoNewline; Write-Host " $msg" }
function Write-Err($msg)  { Write-Host "  " -NoNewline; Write-Host "$([char]0x2717)" -ForegroundColor Red -NoNewline; Write-Host " $msg" }
function Die($msg) { Write-Err $msg; exit 1 }

# ── Detect architecture ─────────────────────────────────────────────────
function Get-CodedbPlatform {
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        "AMD64"   { return "x86_64-windows" }
        "ARM64"   { return "aarch64-windows" }
        default   { Die "Unsupported architecture: $arch" }
    }
}

# ── Get artifact filename ───────────────────────────────────────────────
function Get-ArtifactName($platform) {
    return "codedb-${platform}.exe"
}

# ── Fetch latest version tag ─────────────────────────────────────────────
function Get-LatestVersion {
    # Unauthenticated API (works for public repos)
    try {
        $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/${ForkRepo}/releases/latest" -UserAgent "codedb-setup"
        return $resp.tag_name
    } catch {
        return $null
    }
}

# ── Strip v/V prefix ────────────────────────────────────────────────────
function Strip-VersionPrefix($tag) {
    return $tag -replace '^[vV]', ''
}

# ── Download binary ──────────────────────────────────────────────────────
function Get-VerifiedHash($text, $artifact) {
    $entries = @($text -split "`n" | Where-Object { $_.Trim() -ne '' } | ForEach-Object {
        if ($_ -notmatch '^([0-9a-fA-F]{64}) [ *]([^\r\n]+)\r?$') { throw "Malformed checksum manifest" }
        if ($Matches[2].TrimEnd("`r") -ceq $artifact) { $Matches[1].ToLowerInvariant() }
    })
    if ($entries.Count -ne 1) { throw "Expected exactly one checksum for $artifact" }
    return $entries[0]
}

function Download-Binary($platform, $tag, $dest) {
    $artifact = Get-ArtifactName $platform
    $destDir = Split-Path $dest -Parent
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $tmp = Join-Path $destDir (".codedb-download-" + [Guid]::NewGuid().ToString('N'))
    try {
        $stream = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        $baseUrl = "https://github.com/${ForkRepo}/releases/download/${tag}"
        Invoke-WebRequest -Uri "$baseUrl/$artifact" -OutFile $tmp -UserAgent "codedb-setup" -UseBasicParsing | Out-Null
        $manifest = (Invoke-WebRequest -Uri "$baseUrl/checksums.sha256" -UserAgent "codedb-setup" -UseBasicParsing).Content
        $expected = Get-VerifiedHash $manifest $artifact
        $actual = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "Checksum mismatch" }
        Write-Ok "Checksum verified"
        # A locked executable is an error; never kill clients or delete first.
        if (Test-Path -LiteralPath $dest) { [IO.File]::Replace($tmp, $dest, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $dest) }
        Write-Ok "Installed to $dest"
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

# ── Agent Instructions ───────────────────────────────────────────────────
function Show-AgentInstructions($agentName, $exePath) {
    Write-Host ""
    Write-Host "  Instructions for $agentName" -ForegroundColor White
    Write-Host ""

    $exePathEscaped = $exePath -replace '\\', '\\'

    switch -Regex ($agentName) {
        "(?i)Hermes" {
            $config = "~/.hermes/config.yaml"
            Write-Host "  Add the following to $config :"
            Write-Host ""
            Write-Host "  mcp_servers:" -ForegroundColor Cyan
            Write-Host "    codedb:" -ForegroundColor Cyan
            Write-Host "      command: $exePath" -ForegroundColor Cyan
            Write-Host "      args: [`"mcp`"]" -ForegroundColor Cyan
            Write-Host "      enabled: true" -ForegroundColor Cyan
        }
        "(?i)Copilot" {
            $globalConfig = "~/.copilot/mcp-config.json"
            Write-Host "  To register globally, add to $globalConfig :"
            Write-Host ""
            Write-Host "  {`n    `"mcpServers`": {`n      `"codedb`": {`n        `"command`": `"$exePathEscaped`",`n        `"args`": [`"mcp`"]`n      }`n    }`n  }" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  To register for a specific VS Code workspace, add to .vscode/mcp.json :"
            Write-Host ""
            Write-Host "  {`n    `"servers`": {`n      `"codedb`": {`n        `"type`": `"stdio`",`n        `"command`": `"$exePathEscaped`",`n        `"args`": [`"`${workspaceFolder}`", `"mcp`"]`n      }`n    }`n  }" -ForegroundColor Cyan
        }
        "(?i)Claude" {
            $config = "~/.claude.json"
            Write-Host "  Add the following to $config :"
            Write-Host ""
            Write-Host "  {`n    `"mcpServers`": {`n      `"codedb`": {`n        `"command`": `"$exePathEscaped`",`n        `"args`": [`"mcp`"]`n      }`n    }`n  }" -ForegroundColor Cyan
        }
        "(?i)Codex" {
            $config = "~/.codex/config.toml"
            Write-Host "  Add the following to $config :"
            Write-Host ""
            Write-Host "  [mcp_servers.codedb]" -ForegroundColor Cyan
            Write-Host "  command = `"$exePathEscaped`"" -ForegroundColor Cyan
            Write-Host "  args = [`"mcp`"]" -ForegroundColor Cyan
            Write-Host "  startup_timeout_sec = 30" -ForegroundColor Cyan
        }
        "(?i)Antigravity" {
            $config = "~/.gemini/config/mcp_config.json"
            Write-Host "  Add the following to $config :"
            Write-Host ""
            Write-Host "  {`n    `"mcpServers`": {`n      `"codedb`": {`n        `"command`": `"$exePathEscaped`",`n        `"args`": [`"mcp`"]`n      }`n    }`n  }" -ForegroundColor Cyan
        }
        "(?i)Gemini" {
            $config = "~/.gemini/settings.json"
            Write-Host "  Add the following to $config :"
            Write-Host ""
            Write-Host "  {`n    `"mcpServers`": {`n      `"codedb`": {`n        `"command`": `"$exePathEscaped`",`n        `"args`": [`"mcp`"]`n      }`n    }`n  }" -ForegroundColor Cyan
        }
        "(?i)Cursor" {
            $config = "~/.cursor/mcp.json"
            Write-Host "  Add the following to $config :"
            Write-Host ""
            Write-Host "  {`n    `"mcpServers`": {`n      `"codedb`": {`n        `"command`": `"$exePathEscaped`",`n        `"args`": [`"mcp`"]`n      }`n    }`n  }" -ForegroundColor Cyan
        }
        default {
            Write-Err "Unknown agent: $agentName"
            Write-Host "  Available agents: Hermes, Copilot, Claude, Codex, Gemini, Antigravity, Cursor"
        }
    }
    Write-Host ""
}

# ── Main ─────────────────────────────────────────────────────────────────
function Main {
    Write-Host ""
    Write-Host "  codedb setup (Windows)" -ForegroundColor White
    Write-Host ""

    # 1. Detect platform
    $platform = Get-CodedbPlatform
    Write-Info "Platform: $platform"

    # 2. Get version tag
    if (-not $Version) {
        $Version = Get-LatestVersion
    }
    if (-not $Version) {
        Die "Could not fetch latest version from https://github.com/${ForkRepo}/releases"
    }
    Write-Info "Version:  $(Strip-VersionPrefix $Version)"

    # 3. Download and install
    $dest = Join-Path $InstallDir "codedb.exe"
    Download-Binary $platform $Version $dest

    # 4. Check PATH
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$InstallDir*") {
        Write-Host ""
        Write-Warn "$InstallDir is not in your PATH."
        Write-Host ""
        Write-Host "  To add it permanently:" -ForegroundColor Yellow
        Write-Host "    " -NoNewline
        Write-Host "[Environment]::SetEnvironmentVariable('Path', `"`$env:Path;$InstallDir`", 'User')" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Or for this session only:" -ForegroundColor DarkGray
        Write-Host "    " -NoNewline
        Write-Host "`$env:Path += ';$InstallDir'" -ForegroundColor Cyan
        Write-Host ""
    }

    # 5. Agent Instructions
    if ($Agent) {
        Show-AgentInstructions $Agent $dest
    } else {
        Write-Host ""
        Write-Host "  Registration" -ForegroundColor White
        Write-Host "  To get instructions for an AI agent, run with --Agent <Name>" -ForegroundColor DarkGray
        Write-Host "  Available agents: Hermes, Copilot, Claude, Codex, Gemini, Antigravity, Cursor" -ForegroundColor DarkGray
    }

    # 6. Clear snapshot cache
    Write-Host ""
    Write-Host "  Clearing stale snapshot cache..." -ForegroundColor White
    $cacheDir = Join-Path $env:USERPROFILE ".codedb\projects"
    if (Test-Path $cacheDir) {
        $files = Get-ChildItem -Path "$cacheDir\*\codedb.snapshot" -ErrorAction SilentlyContinue
        if ($files) {
            $files | Remove-Item -Force
            Write-Ok "Deleted $($files.Count) snapshots from $cacheDir"
        } else {
            Write-Skip "No snapshots found in cache"
        }
    } else {
        Write-Skip "Cache directory not found ($cacheDir)"
    }

    # 7. Done
    Write-Host ""
    Write-Host "  Done!" -ForegroundColor Green
    Write-Host "  Binary installed at: $dest" -ForegroundColor DarkGray
    Write-Host "  Open a project and ask your agent about the codebase." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Update:    powershell -File scripts/setup-codedb.ps1" -ForegroundColor DarkGray
    Write-Host "  Uninstall: codedb nuke" -ForegroundColor DarkGray
    Write-Host ""
}

if ($MyInvocation.InvocationName -ne ".") { Main }
