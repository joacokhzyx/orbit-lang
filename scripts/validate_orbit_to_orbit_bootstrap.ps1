param(
    [string]$Source = "compiler_self_hosting.orb"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[orbit2orbit] Building $Source"
& zig build run -- build $Source
if ($LASTEXITCODE -ne 0) {
    throw "Orbit-to-Orbit build failed"
}

$serverExe = Join-Path $root "orbit.exe"
if (-not (Test-Path $serverExe)) {
    throw "orbit.exe was not generated"
}

Write-Host "[orbit2orbit] Running CLI binary"
$outputLines = & $serverExe 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($outputLines | Out-String)

Write-Host "[orbit2orbit] Process exit: $exitCode"
Write-Host "[orbit2orbit] CLI output:"
Write-Host $outputText

if ($exitCode -ne 0) {
    throw "Orbit-to-Orbit CLI run failed"
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
        throw "Missing expected CLI output snippet: $snippet"
    }
}

Write-Host "[orbit2orbit] Orbit-to-Orbit CLI validation passed"
