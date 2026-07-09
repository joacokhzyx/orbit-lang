param(
    [string]$Source = "compiler/main.orb"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[stage1-cli] Building $Source"
& zig build run -- build $Source
if ($LASTEXITCODE -ne 0) {
    throw "Stage-1 CLI build failed"
}

$bin = Join-Path $root "orbit.exe"
if (-not (Test-Path $bin)) {
    throw "orbit.exe was not generated"
}

Write-Host "[stage1-cli] Running CLI binary"
$outputLines = & $bin 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($outputLines | Out-String)

Write-Host "[stage1-cli] Process exit: $exitCode"
Write-Host "[stage1-cli] CLI output:"
Write-Host $outputText

if ($exitCode -ne 0) {
    throw "Stage-1 CLI run failed"
}

$expectedSnippets = @(
    "Orbit Compiler in Orbit - Stage-1 CLI",
    "[phase] load-source",
    "compiler/main.orb",
    "compiler/lexer.orb",
    "Stage-1 compile pipeline executed",
    "Stage-1 lexer compile pipeline executed"
)

foreach ($snippet in $expectedSnippets) {
    if ($outputText.Contains($snippet) -eq $false) {
        throw "Missing expected Stage-1 CLI output snippet: $snippet"
    }
}

Write-Host "[stage1-cli] Stage-1 CLI validation passed"
