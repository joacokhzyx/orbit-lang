param(
    [switch]$SkipRuntime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[ci] Running bootstrap regression gate"
if ($SkipRuntime) {
    & powershell -ExecutionPolicy Bypass -File .\scripts\run_bootstrap_regressions.ps1 -SkipRuntime
}
else {
    & powershell -ExecutionPolicy Bypass -File .\scripts\run_bootstrap_regressions.ps1
}

if ($LASTEXITCODE -ne 0) {
    throw "Bootstrap regression gate failed"
}

Write-Host "[ci] Running zig build"
& zig build
if ($LASTEXITCODE -ne 0) {
    throw "zig build failed"
}

Write-Host "[ci] Running zig build test"
& zig build test
if ($LASTEXITCODE -ne 0) {
    throw "zig build test failed"
}

Write-Host "[ci] CI gate passed"