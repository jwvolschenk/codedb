# Offline publisher failure-injection checks. No builds, pushes, or network access.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/publish-codedb.ps1"
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codedb-publisher-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $fixture 'src')) | Out-Null
$script:RepoDir = $fixture
$versionFile = Join-Path $fixture 'src/release_info.zig'
$manifestFile = Join-Path $fixture 'build.zig.zon'
$reportFile = Join-Path $fixture 'performance.json'
$originalVersion = "pub const semver = `"1.0.0`";`r`n"
$originalManifest = '.{ .version = "1.0.0", }'
[IO.File]::WriteAllText($versionFile, $originalVersion)
[IO.File]::WriteAllText($manifestFile, $originalManifest)
$Tag = 'v1.0.1'
$Targets = @('x86_64-windows', 'aarch64-linux')
$ZigPath = 'mock-zig'
$PerformanceReport = $reportFile
$script:calls = @()
$script:mode = ''
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
    Assert $caught "Expected failure: $Pattern"
}
# Exercise the real wrapper before replacing native commands with mocks.
Expect-Failure { Invoke-Native powershell.exe @('-NoProfile', '-Command', 'exit 7') } 'exit 7'
Write-Host 'PASS native exit-code propagation'
# Only dependency discovery is mocked; the publisher logic and file IO are real.
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    return @{ Source = $Name }
}
$script:confirmation = 'y'
function Read-Host { return $script:confirmation }
function Invoke-Native {
    param([string]$Program, [string[]]$Arguments)
    $script:calls += "$Program $($Arguments -join ' ')"
    if ($Program -eq 'mock-zig') {
        if ($Arguments[0] -eq 'version') {
            if ($script:mode -eq 'wrong-zig') { return '0.15.2' }
            return '0.16.0'
        }
        Assert ([IO.File]::ReadAllText($versionFile).Contains('"' + $Tag.Substring(1) + '"')) 'Build version mismatch'
        Assert ([IO.File]::ReadAllText($manifestFile).Contains('"' + $Tag.Substring(1) + '"')) 'Package version mismatch'
        if ($script:mode -eq 'build-fail') { throw 'Mock build failed' }
        $prefix = $Arguments[[Array]::IndexOf($Arguments, '--prefix') + 1]
        $bin = Join-Path $prefix 'bin'
        [IO.Directory]::CreateDirectory($bin) | Out-Null
        $name = if ($Arguments -contains '-Dtarget=x86_64-windows') { 'codedb.exe' } else { 'codedb' }
        [IO.File]::WriteAllText((Join-Path $bin $name), 'synthetic binary')
        return
    }
    if ($Program -eq 'gh') {
        if ($Arguments[0] -eq 'api') { return 'true' }
        return
    }
    switch ($Arguments[0]) {
        'status' { if ($script:mode -eq 'dirty') { return ' M unrelated.zig' }; return }
        'branch' { return 'test-branch' }
        'rev-parse' { return 'fixture-commit' }
        'remote' { return 'https://github.com/jwvolschenk/codedb.git' }
        'tag' {
            if ($Arguments -contains '--list' -and $script:mode -eq 'existing-tag') { return 'v1.0.1' }
            if ($Arguments -contains '-a') {
                Assert ([IO.File]::ReadAllText($versionFile).Contains('"' + $Tag.Substring(1) + '"')) 'Tag version mismatch'
            }
            return
        }
        'diff' { return @('src/release_info.zig', 'build.zig.zon') }
        'push' { if ($script:mode -eq 'push-fail') { throw 'Mock push failed' }; return }
        default { return }
    }
}
try {
    foreach ($invalid in @('--help', 'v1.2.3";', 'v01.2.3', 'v1.2.3-01', "v1.2.3`n")) {
        Expect-Failure { Assert-ReleaseTag $invalid } 'semver'
    }
    foreach ($valid in @('v1.2.3', 'v1.2.3-rc.1', 'v1.2.3+build.4')) { Assert-ReleaseTag $valid }
    Assert ((Get-ArtifactName 'aarch64-macos') -eq 'codedb-aarch64-darwin') 'macOS naming'
    Expect-Failure { Get-ArtifactName '../escape' } 'Unsupported'
    $BuildOnly = $true
    foreach ($case in @('dirty', 'wrong-zig', 'build-fail')) {
        $script:mode = $case; $script:calls = @()
        $pattern = switch ($case) { 'dirty' { 'not clean' }; 'wrong-zig' { '0.16.0 required' }; 'build-fail' { 'Mock build failed' } }
        Expect-Failure { Publish-CodeDb } $pattern
        Assert ([IO.File]::ReadAllText($versionFile) -ceq $originalVersion) 'Version not restored'
        Assert ([IO.File]::ReadAllText($manifestFile) -ceq $originalManifest) 'Manifest not restored'
        Assert (!@($script:calls | Where-Object { $_ -match '^git (push|commit|tag -a)' }).Count) 'Unexpected Git mutation'
        Write-Host "PASS $case"
    }
    $script:mode = ''; $script:calls = @()
    Publish-CodeDb
    Assert ([IO.File]::ReadAllText($versionFile) -ceq $originalVersion) 'Build-only source changed'
    $manifests = @(Get-ChildItem -LiteralPath (Join-Path $fixture '.release') -Recurse -Filter checksums.sha256)
    Assert ($manifests.Count -eq 1) 'Missing checksum manifest'
    $lines = @(Get-Content -LiteralPath $manifests[0].FullName)
    Assert ($lines.Count -eq 2) 'Incorrect artifact count'
    foreach ($line in $lines) {
        $hash, $name = $line -split '  ', 2
        Assert ($hash -ceq (Get-FileHash -LiteralPath (Join-Path $manifests[0].DirectoryName $name)).Hash.ToLowerInvariant()) 'Checksum mismatch'
    }
    Assert (!@($script:calls | Where-Object { $_ -match '^gh |^git (push|commit|tag -a)' }).Count) 'Build-only published'
    Write-Host 'PASS build-only and checksums'
    $BuildOnly = $false
    [IO.File]::WriteAllText($reportFile, '{"gate":"FAIL","threshold_percent":10,"comparisons":[{"gate":"FAIL","delta_percent":11}]}')
    $script:calls = @()
    Expect-Failure { Publish-CodeDb } '10% performance gate'
    Assert (!@($script:calls | Where-Object { $_ -match '^gh |mock-zig build|^git push' }).Count) 'Failed gate allowed release'
    Write-Host 'PASS failing performance gate'
    [IO.File]::WriteAllText($reportFile, '{"gate":"PASS","threshold_percent":10,"comparisons":[{"gate":"PASS","delta_percent":11}]}')
    Expect-Failure { Publish-CodeDb } '10% performance gate'
    [IO.File]::WriteAllText($reportFile, '{"gate":"PASS","threshold_percent":10,"comparisons":[{"gate":"PASS","delta_percent":1}]}')
    $script:mode = 'existing-tag'
    Expect-Failure { Publish-CodeDb } 'already exists'
    Write-Host 'PASS existing tag rejected'
    $script:mode = ''; $script:calls = @(); $script:confirmation = 'n'
    Publish-CodeDb
    Assert ([IO.File]::ReadAllText($versionFile) -ceq $originalVersion) 'Cancelled source changed'
    Assert (!@($script:calls | Where-Object { $_ -match '^git (push|commit|tag -a)|^gh release' }).Count) 'Cancelled release published'
    Write-Host 'PASS cancellation retains artifacts and restores source'
    $script:confirmation = 'y'
    $script:mode = 'push-fail'; $script:calls = @()
    Expect-Failure { Publish-CodeDb } 'Mock push failed'
    Assert (!@($script:calls | Where-Object { $_ -match '^git tag -a|^gh release' }).Count) 'Push failure allowed publication'
    Write-Host 'PASS push failure stops publication'
    $script:mode = ''; $script:calls = @()
    Publish-CodeDb
    $joined = $script:calls -join "`n"
    Assert ($joined -match '(?s)mock-zig build.*git commit.*git push origin HEAD:.*git tag -a.*git push origin refs/tags/.*gh release create.*--verify-tag') 'Incorrect release ordering'
    Assert ($joined -match 'codedb-x86_64-windows.exe.*checksums.sha256') 'Assets omitted'
    Write-Host 'PASS release ordering and exact tag'
    $Tag = 'v1.0.1-rc.1'; $script:calls = @()
    Publish-CodeDb
    Assert (($script:calls -join "`n") -match 'gh release create.*--prerelease') 'Prerelease flag omitted'
    Write-Host 'PASS prerelease publishing'
} finally {
    # Only remove this test's generated directory after verifying the resolved path.
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'codedb-publisher-test-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
