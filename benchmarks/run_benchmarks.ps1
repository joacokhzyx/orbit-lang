param(
    [int]$Iterations = 10
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " ORBIT PERFORMANCE BENCHMARKS " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Iterations per language: $Iterations" -ForegroundColor Yellow
Write-Host "Warmup runs: 2" -ForegroundColor Yellow
Write-Host ""

# Compile Orbit
Write-Host "Compiling Orbit fib.orb (Release O3)..." -ForegroundColor Green
.\zig-out\bin\orbit build .\benchmarks\fib.orb

# Orbit produces orbit.exe by default in the current directory
if (-not (Test-Path ".\orbit.exe")) {
    Write-Host "Failed to compile fib.orb" -ForegroundColor Red
    exit 1
}

# Rename it so it's clear
Move-Item -Path ".\orbit.exe" -Destination ".\fib.exe" -Force

function Run-Benchmark($name, $cmd, $argList) {
    Write-Host "Running $name benchmark..." -NoNewline
    
    # Warmup
    for ($i = 0; $i -lt 2; $i++) {
        if ($argList -eq "") {
            $null = & $cmd
        } else {
            $null = & $cmd $argList
        }
    }

    $totalMilliseconds = 0
    for ($i = 0; $i -lt $Iterations; $i++) {
        if ($argList -eq "") {
            $time = Measure-Command { $null = & $cmd }
        } else {
            $time = Measure-Command { $null = & $cmd $argList }
        }
        $totalMilliseconds += $time.TotalMilliseconds
    }
    
    $avg = $totalMilliseconds / $Iterations
    Write-Host " Done. Avg: $([math]::Round($avg, 2)) ms" -ForegroundColor Green
    return $avg
}

$orbitTime = Run-Benchmark "Orbit (C -O3)" ".\fib.exe" ""
$jsTime = Run-Benchmark "Node.js (V8)" "node" ".\benchmarks\fib.js"
$pyTime = Run-Benchmark "Python (CPython)" "python" ".\benchmarks\fib.py"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " RESULTS SUMMARY (Fibonacci 36)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Orbit:   $([math]::Round($orbitTime, 2)) ms" -ForegroundColor Green
Write-Host " Node.js: $([math]::Round($jsTime, 2)) ms" -ForegroundColor Yellow
Write-Host " Python:  $([math]::Round($pyTime, 2)) ms" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan

# Cleanup
Remove-Item ".\fib.exe" -ErrorAction SilentlyContinue
Remove-Item ".\fib.c" -ErrorAction SilentlyContinue
Remove-Item ".\orbit.c" -ErrorAction SilentlyContinue
