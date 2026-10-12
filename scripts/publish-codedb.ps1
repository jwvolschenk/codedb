# Native Windows release publisher. Requires PowerShell 5.1+, Git, Zig 0.16.0,
# and the authenticated GitHub CLI (gh). See docs/release-validation.md.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Tag,
    [string[]]$Targets,
    [string]$ZigPath,
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
$script:RepoDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ReleaseRepo = 'jwvolschenk/codedb'
$script:AllTargets = @('x86_64-linux', 'aarch64-linux', 'x86_64-macos', 'aarch64-macos', 'x86_64-windows', 'aarch64-windows')

# PowerShell 5.1 does not throw when a native command fails. Check every exit.
function Invoke-Native {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}

function Get-ArtifactName {
    param([string]$Target)
    if ($Target -notin $script:AllTargets) { throw "Unsupported target: $Target" }
    $name = 'codedb-' + ($Target -replace '-macos$', '-darwin')
    if ($Target.EndsWith('-windows')) { $name += '.exe' }
    return $name
}

function Assert-ReleaseTag {
    param([string]$Value)
    # Restrict both Git arguments and injected Zig strings to valid semver tags.
    $number = '(0|[1-9][0-9]*)'
    $identifier = '(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    if ($Value -cnotmatch "\Av$number\.$number\.$number(-$identifier(\.$identifier)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?\z") {
        throw "Use a semver tag such as v3.1.1 or v3.2.0-rc.1."
    }
}

function Select-ReleaseTag {
    $tags = @(Invoke-Native git @('tag', '--sort=-version:refname'))
    $latest = $tags | Where-Object { $_ -match '^v[0-9]+\.[0-9]+\.[0-9]+$' } | Select-Object -First 1
    if (!$latest) { return (Read-Host 'Version tag (e.g. v1.0.0)') }
    $parts = $latest.Substring(1).Split('.')
    $major = [long]$parts[0]; $minor = [long]$parts[1]; $patch = [long]$parts[2]
    $patchTag = "v$major.$minor.$($patch + 1)"
    $minorTag = "v$major.$($minor + 1).0"
    $majorTag = "v$($major + 1).0.0"
    Write-Host "Latest local version: $latest"
    Write-Host "1) $patchTag (patch)  2) $minorTag (minor)  3) $majorTag (major)  4) custom"
    switch (Read-Host 'Choice [1]') {
        '' { return $patchTag }
        '1' { return $patchTag }
        '2' { return $minorTag }
        '3' { return $majorTag }
        '4' { return (Read-Host 'Version tag') }
        default { throw 'Invalid version choice.' }
    }
}

function Publish-CodeDb {
    Push-Location -LiteralPath $script:RepoDir
    try {
        foreach ($command in @('git')) { Get-Command $command -CommandType Application -ErrorAction Stop | Out-Null }
        if (@(Invoke-Native git @('status', '--porcelain')).Count) {
            throw 'Working tree is not clean. Commit or stash changes before publishing or building a release.'
        }
        $branch = (Invoke-Native git @('branch', '--show-current') | Out-String).Trim()
        if (!$branch) { throw 'A checked-out branch is required.' }
        $sourceCommit = (Invoke-Native git @('rev-parse', 'HEAD') | Out-String).Trim()
        if (!$Tag) { $Tag = Select-ReleaseTag }
        Assert-ReleaseTag $Tag

        if (!$Targets) {
            if ($env:PLATFORMS) { $Targets = @($env:PLATFORMS.Trim() -split '\s+') }
            else { $Targets = $script:AllTargets }
        }
        $Targets = @($Targets | Select-Object -Unique)
        foreach ($target in $Targets) { Get-ArtifactName $target | Out-Null }
        if (!$ZigPath) {
            $bundled = Join-Path $script:RepoDir '.build/zig-x86_64-windows-0.16.0/zig.exe'
            if (Test-Path -LiteralPath $bundled -PathType Leaf) { $ZigPath = $bundled }
            else { $ZigPath = (Get-Command zig -CommandType Application -ErrorAction Stop).Source }
        }
        $zigVersion = (Invoke-Native $ZigPath @('version') | Out-String).Trim()
        if ($zigVersion -ne '0.16.0') { throw "Zig 0.16.0 required; found $zigVersion. Supply -ZigPath to the verified compiler." }

        if (!$BuildOnly) {
            Get-Command gh -CommandType Application -ErrorAction Stop | Out-Null
            Invoke-Native gh @('auth', 'status') | Out-Host
            $access = (Invoke-Native gh @('api', "repos/$script:ReleaseRepo", '--jq', '.permissions.push') | Out-String).Trim()
            if ($access -ne 'true') { throw "Active gh account cannot push to $script:ReleaseRepo. Use gh auth switch --user <account>." }
            $origins = @(Invoke-Native git @('remote', 'get-url', '--push', '--all', 'origin'))
            if ($origins.Count -ne 1 -or $origins[0] -notmatch '\A((https://github\.com/)|(git@github\.com:)|(ssh://git@github\.com/))jwvolschenk/codedb(\.git)?\z') {
                throw "origin must have exactly one push URL pointing to $script:ReleaseRepo."
            }
            $existing = @(Invoke-Native git @('tag', '--list', $Tag))
            $remote = @(Invoke-Native git @('ls-remote', '--tags', 'origin', "refs/tags/$Tag", "refs/tags/$Tag^{}"))
            if ($existing.Count -or $remote.Count) { throw "Tag $Tag already exists. Use a new version; existing tags are never overwritten." }
        }

        # A fresh directory prevents old or partially rebuilt binaries being uploaded.
        $releaseRoot = Join-Path $script:RepoDir '.release'
        $output = Join-Path $releaseRoot ("$Tag-" + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($output) | Out-Null
        $versionFile = Join-Path $script:RepoDir 'src/release_info.zig'
        $manifestFile = Join-Path $script:RepoDir 'build.zig.zon'
        $versionBytes = [IO.File]::ReadAllBytes($versionFile)
        $manifestBytes = [IO.File]::ReadAllBytes($manifestFile)
        $manifest = [IO.File]::ReadAllText($manifestFile)
        if ([regex]::Matches($manifest, '\.version\s*=\s*"[^"]*"').Count -ne 1) {
            throw 'Expected exactly one package version in build.zig.zon.'
        }
        $semver = $Tag.Substring(1)
        $updatedManifest = [regex]::Replace($manifest, '\.version\s*=\s*"[^"]*"', ".version = `"$semver`"")
        $utf8 = New-Object Text.UTF8Encoding($false)
        $artifacts = @()
        try {
            [IO.File]::WriteAllText($versionFile, "pub const semver = `"$semver`";`n", $utf8)
            [IO.File]::WriteAllText($manifestFile, $updatedManifest, $utf8)
            foreach ($target in $Targets) {
                Write-Host "Building $target with Zig $zigVersion..."
                $prefix = Join-Path $output $target
                Invoke-Native $ZigPath @('build', '-Doptimize=ReleaseFast', "-Dtarget=$target", '--prefix', $prefix) | Out-Host
                $binaryName = if ($target.EndsWith('-windows')) { 'codedb.exe' } else { 'codedb' }
                $destination = Join-Path $output (Get-ArtifactName $target)
                Copy-Item -LiteralPath (Join-Path $prefix "bin/$binaryName") -Destination $destination
                $artifacts += $destination
            }
            $checksums = @($artifacts | Sort-Object | ForEach-Object {
                (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($_)
            })
            $checksumFile = Join-Path $output 'checksums.sha256'
            [IO.File]::WriteAllText($checksumFile, ($checksums -join "`n") + "`n", $utf8)
            $artifacts += $checksumFile
        } finally {
            # Keep the caller's source bytes intact on build failure or cancellation.
            [IO.File]::WriteAllBytes($versionFile, $versionBytes)
            [IO.File]::WriteAllBytes($manifestFile, $manifestBytes)
        }
        Write-Host "Artifacts: $output"
        if ($BuildOnly) { return }
        Write-Host "This will commit both version files, push $branch, tag $Tag, and publish $($Targets.Count) binaries to $script:ReleaseRepo."
        Write-Host 'Complete the remaining validation in docs/release-validation.md before continuing.'
        if ((Read-Host 'Publish this release? [y/N]') -notmatch '^[yY]$') { Write-Host 'Publish cancelled. Local artifacts retained.'; return }
        # Detect concurrent edits rather than accidentally committing them.
        if (@(Invoke-Native git @('status', '--porcelain')).Count) { throw 'Working tree changed during builds. Release cancelled.' }
        if ((Invoke-Native git @('rev-parse', 'HEAD') | Out-String).Trim() -ne $sourceCommit -or
            (Invoke-Native git @('branch', '--show-current') | Out-String).Trim() -ne $branch) {
            throw 'Source commit or branch changed during builds. Release cancelled.'
        }
        [IO.File]::WriteAllText($versionFile, "pub const semver = `"$semver`";`n", $utf8)
        [IO.File]::WriteAllText($manifestFile, $updatedManifest, $utf8)
        Invoke-Native git @('add', '--', 'src/release_info.zig', 'build.zig.zon') | Out-Host
        $changes = @(Invoke-Native git @('diff', '--cached', '--name-only'))
        if ($changes.Count) { Invoke-Native git @('commit', '-m', "release: $Tag") | Out-Host }
        Invoke-Native git @('push', 'origin', "HEAD:refs/heads/$branch") | Out-Host
        Invoke-Native git @('tag', '-a', $Tag, '-m', "Release $Tag") | Out-Host
        Invoke-Native git @('push', 'origin', "refs/tags/$Tag") | Out-Host
        # Require the pushed tag; gh must never implicitly create a different tag.
        $releaseArgs = @('release', 'create', $Tag, '--repo', $script:ReleaseRepo, '--verify-tag', '--title', "codedb $Tag", '--generate-notes')
        if ($semver.Contains('-')) { $releaseArgs += '--prerelease' }
        Invoke-Native gh ($releaseArgs + $artifacts) | Out-Host
        Write-Host "https://github.com/$script:ReleaseRepo/releases/tag/$Tag"
    } finally { Pop-Location }
}

# Dot sourcing exposes helpers to the offline failure-injection suite.
if ($MyInvocation.InvocationName -ne '.') { Publish-CodeDb }
