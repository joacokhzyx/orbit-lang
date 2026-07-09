param(
    [switch]$SkipRuntime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Invoke-OrbitCompileCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Source
    )

    Write-Host "[regression] Building $Source"

    $outputLines = cmd /c "zig build run -- build $Source 2>&1"
    $exitCode = $LASTEXITCODE
    $outputText = ($outputLines | Out-String)
    $hasWarning = $outputText -match "(?im)\bwarning:"

    if ($outputText -match "non-void function does not return a value") {
        throw "Regression detected in ${Source}: non-void return warning"
    }

    if ($hasWarning) {
        Write-Host $outputText
        throw "Regression detected in ${Source}: compiler warnings present"
    }

    if ($exitCode -ne 0) {
        Write-Host $outputText
        throw "Build failed for $Source"
    }
}
function Invoke-DuplicateRegressionCheck {
    $runner = "tests/bootstrap/fixtures/sema_duplicate_runner.orb"

    Write-Host "[regression] Building duplicate-detection runner $runner"
    $buildOutput = cmd /c "zig build run -- build $runner 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($buildOutput | Out-String)
        throw "Build failed for $runner"
    }

    Write-Host "[regression] Running duplicate-detection gate"
    # NOTE: el binario se llama segun output_name del orbit.atlas (orbit.exe).
    $runOutput = cmd /c ".\orbit.exe 2>&1"
    $runExit = $LASTEXITCODE
    $runText = ($runOutput | Out-String)

    if ($runExit -eq 0) {
        Write-Host $runText
        throw "Duplicate-detection gate did not fail: expected non-zero exit code for duplicate declarations"
    }

    if ($runText -notmatch "duplicate declaration 'foo'") {
        Write-Host $runText
        throw "Duplicate-detection gate did not report the expected duplicate declaration"
    }

    Write-Host "[regression] Duplicate-detection gate OK (exit=$runExit, duplicate reported)"
}

$targets = @(
    "compiler/main.orb",
    "compiler_self_hosting.orb",
    "tests/bootstrap/fixtures/import_chain.orb",
    "tests/bootstrap/fixtures/typed_return.orb",
    "tests/bootstrap/fixtures/nested_call.orb",
    "tests/bootstrap/fixtures/string_concat.orb",
    "tests/bootstrap/fixtures/string_concat_mixed.orb",
    "tests/bootstrap/fixtures/rescue_expr.orb",
    "tests/bootstrap/fixtures/rescue_concat_cli.orb",
    "tests/bootstrap/fixtures/parser_top_level_cli.orb"
)

foreach ($target in $targets) {
    Invoke-OrbitCompileCheck -Source $target
}

if (-not $SkipRuntime) {
    Write-Host "[regression] Validating Stage-1 CLI bootstrap"
    & .\scripts\validate_stage1_cli_bootstrap.ps1 `
        -Source "compiler/main.orb"
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime validation failed for Stage-1 CLI bootstrap"
    }

    Write-Host "[regression] Validating Stage-2 CLI bootstrap"
    & .\scripts\validate_stage2_cli_bootstrap.ps1 `
        -Source "compiler_self_hosting.orb"
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime validation failed for Stage-2 CLI bootstrap"
    }

    Write-Host "[regression] Validating rescue+concat CLI fixture"
    $rescueExpectedOutputs = @("Rescue concat CLI fixture", "rescue=MISSING, n=7, ok=true, r=2.5")
    & .\scripts\validate_cli_fixture.ps1 `
        -Source "tests/bootstrap/fixtures/rescue_concat_cli.orb" `
        -ExpectedOutputs $rescueExpectedOutputs
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime validation failed for rescue+concat CLI fixture"
    }

    Write-Host "[regression] Validating top-level parser CLI fixture"
    $parserExpectedOutputs = @("Top-level parser CLI fixture", "decl=6", "fn runFixture", "route GET /fixture", "type FixtureAlias")
    & .\scripts\validate_cli_fixture.ps1 `
        -Source "tests/bootstrap/fixtures/parser_top_level_cli.orb" `
        -ExpectedOutputs $parserExpectedOutputs
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime validation failed for top-level parser CLI fixture"
    }

    Write-Host "[regression] Validating Orbit-to-Orbit self-host CLI mode"
    & .\scripts\validate_orbit_to_orbit_bootstrap.ps1 `
        -Source "compiler_self_hosting.orb"
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime validation failed for Orbit-to-Orbit self-host endpoints"
    }
    
    Write-Host "[regression] Validating duplicate-declaration detection"
    Invoke-DuplicateRegressionCheck
}

Write-Host "[regression] Bootstrap regression gate passed"