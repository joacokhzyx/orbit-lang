param(
    [string]$Source = "compiler_self_hosting.orb"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[stage2-cli] Building $Source"
& zig build run -- build $Source
if ($LASTEXITCODE -ne 0) {
    throw "Stage-2 CLI build failed"
}

$bin = Join-Path $root "orbit.exe"
if (-not (Test-Path $bin)) {
    throw "orbit.exe was not generated"
}

Write-Host "[stage2-cli] Running CLI binary"
$outputLines = & $bin 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($outputLines | Out-String)

Write-Host "[stage2-cli] Process exit: $exitCode"
Write-Host "[stage2-cli] CLI output:"
Write-Host $outputText

if ($exitCode -ne 0) {
    throw "Stage-2 CLI run failed"
}

$expectedSnippets = @(
    "Orbit Compiler in Orbit - Stage-2 CLI",
    "[stage2] source",
    "[stage2] declarations",
    "lex_fn=",
    "top_fn=",
    "compiler_self_hosting.orb",
    "compiler/main.orb",
    "compiler/lexer.orb",
    "fn main",
    "[stage2] done"
)

foreach ($snippet in $expectedSnippets) {
    if ($outputText.Contains($snippet) -eq $false) {
        throw "Missing expected Stage-2 CLI output snippet: $snippet"
    }
}

Write-Host "[stage2-cli] Stage-2 CLI validation passed"