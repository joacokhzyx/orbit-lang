param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string[]]$ExpectedOutputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[cli-fixture] Building $Source"
& zig build run -- build $Source
if ($LASTEXITCODE -ne 0) {
    throw "CLI fixture build failed: $Source"
}

$bin = Join-Path $root "orbit.exe"
if (-not (Test-Path $bin)) {
    throw "orbit.exe was not generated"
}

Write-Host "[cli-fixture] Running CLI binary"
$outputLines = & $bin 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($outputLines | Out-String)

Write-Host "[cli-fixture] Process exit: $exitCode"
Write-Host "[cli-fixture] CLI output:"
Write-Host $outputText

if ($exitCode -ne 0) {
    throw "CLI fixture run failed"
}

foreach ($expectedSnippet in $ExpectedOutputs) {
    if ($outputText.Contains($expectedSnippet) -eq $false) {
        throw "Missing expected fixture output snippet: $expectedSnippet"
    }
}

Write-Host "[cli-fixture] CLI fixture validation passed"
