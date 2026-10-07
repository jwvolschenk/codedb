# Offline failure-injection tests; no release downloads or client registration.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/setup-codedb.ps1"
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('codedb-installer-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDir) | Out-Null
$dest = Join-Path $testDir 'codedb.exe'
$script:testCase = ''
$script:newBytes = [Text.Encoding]::UTF8.GetBytes('verified-new-binary')
$sha = [Security.Cryptography.SHA256]::Create()
$script:hash = ([BitConverter]::ToString($sha.ComputeHash($script:newBytes))).Replace('-', '').ToLowerInvariant()
$sha.Dispose()
function Invoke-WebRequest {
    param($Uri, $OutFile, $UserAgent, [switch]$UseBasicParsing)
    if ($script:testCase -eq 'http') { throw 'Mock HTTP failure' }
    if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, $script:newBytes); return }
    $line = "$script:hash  codedb-x86_64-windows.exe"
    $manifest = switch ($script:testCase) {
        'missing' { "$script:hash  another.exe" }
        'malformed' { 'invalid  codedb-x86_64-windows.exe' }
        'duplicate' { "$line`n$line" }
        'mismatch' { ('0' * 64) + '  codedb-x86_64-windows.exe' }
        default { $line }
    }
    return @{Content = $manifest}
}
try {
    foreach ($case in @('http', 'missing', 'malformed', 'duplicate', 'mismatch', 'success')) {
        $script:testCase = $case
        [IO.File]::WriteAllText($dest, 'original-binary')
        $failed = $false
        try { Download-Binary 'x86_64-windows' 'test' $dest } catch { $failed = $true; if ($case -eq 'success') { throw } }
        if ($case -eq 'success') {
            if ($failed -or [IO.File]::ReadAllText($dest) -ne 'verified-new-binary') { throw 'Verified install failed' }
        } else {
            if (!$failed -or [IO.File]::ReadAllText($dest) -ne 'original-binary') { throw "Old binary was not preserved: $case" }
        }
        if (@(Get-ChildItem -LiteralPath $testDir -Filter '.codedb-download-*').Count) { throw 'Temporary download leaked' }
        Write-Host "PASS $case"
    }
} finally {
    # Remove only the exact files created by this test; no recursive cleanup.
    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    [IO.Directory]::Delete($testDir)
}
