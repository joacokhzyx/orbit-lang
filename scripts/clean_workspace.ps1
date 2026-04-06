param(
    [switch]$IncludeBuildCache
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$targets = @(
    "build_detailed.txt",
    "build_errors.txt",
    "build_error_full.txt",
    "build_log.txt",
    "build_output.txt",
    "build.log",
    "error.txt",
    "error.log",
    "output.txt",
    "output.log",
    "test_output.txt",
    "output_orbit.c",
    "*.exe",
    "*.pdb"
)

foreach ($pattern in $targets) {
    Get-ChildItem -Path $root -Filter $pattern -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

if ($IncludeBuildCache) {
    foreach ($dir in @(".zig-cache", "zig-out")) {
        if (Test-Path $dir) {
            Remove-Item $dir -Recurse -Force
        }
    }
}

Write-Output "Workspace cleanup completed."
