# Orbit Programming Language Automated Windows Installer
# Installs Orbit compiler binary, configures PATH, and registers VS Code Extension.

$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Orbit Programming Language - Automated Setup" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. Prepare Target Directory
$InstallDir = "$env:USERPROFILE\.orbit\bin"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Host "[+] Created Orbit installation directory at: $InstallDir" -ForegroundColor Green
}

# 2. Locate / Build Binary
$RootDir = Split-Path -Parent $PSScriptRoot
$SourceExe = "$RootDir\orbit.exe"
if (-not (Test-Path $SourceExe)) {
    $SourceExe = "$RootDir\zig-out\bin\orbit.exe"
}

if (-not (Test-Path $SourceExe)) {
    Write-Host "[*] Compiling Orbit binary with ReleaseFast optimization..." -ForegroundColor Yellow
    Set-Location $RootDir
    zig build -Doptimize=ReleaseFast
    $SourceExe = "$RootDir\zig-out\bin\orbit.exe"
}

$DestExe = "$InstallDir\orbit.exe"
Copy-Item -Path $SourceExe -Destination $DestExe -Force
Write-Host "[+] Installed Orbit binary to: $DestExe" -ForegroundColor Green

# 3. Add to Environment PATH
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notlike "*$InstallDir*") {
    $NewPath = "$InstallDir;$UserPath"
    [Environment]::SetEnvironmentVariable("PATH", $NewPath, "User")
    Write-Host "[+] Added $InstallDir to User PATH environment variable." -ForegroundColor Green
} else {
    Write-Host "[=] $InstallDir is already in User PATH." -ForegroundColor Gray
}

# 4. Install VS Code Extension
$VsCodeDir = "$env:USERPROFILE\.vscode\extensions\orbit-lang"
$ExtensionSrc = "$RootDir\editors\vscode"

if (Test-Path $ExtensionSrc) {
    if (-not (Test-Path $VsCodeDir)) {
        New-Item -ItemType Directory -Path $VsCodeDir -Force | Out-Null
    }
    Copy-Item -Path "$ExtensionSrc\*" -Destination $VsCodeDir -Recurse -Force
    Write-Host "[+] Registered Orbit VS Code Extension & LSP in: $VsCodeDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " [SUCCESS] Orbit v0.1.0-rc.2 setup completed successfully!" -ForegroundColor Green
Write-Host " Restart your terminal and run 'orbit --help' or open VS Code." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
