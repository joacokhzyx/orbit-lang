# Orbit Programming Language Automated Windows Installer
# Installs the self-hosted Orbit compiler (Zig-free bootstrap), configures PATH,
# and registers the VS Code extension.

param (
    [string]$Cc = $env:ORBIT_CC
)

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
Set-Location $RootDir

$SourceExe = $null

# 2a. Prefer a pre-built fixed-point compiler shipped with a release.
$FixedPoint = "$RootDir\dist\orbit-windows-x86_64.exe"
if (Test-Path $FixedPoint) {
    $SourceExe = $FixedPoint
    Write-Host "[+] Selected released fixed-point compiler: $SourceExe" -ForegroundColor Green
}
else {
    # 2b. Zig-free self-hosted bootstrap from the committed canonical C.
    #     Root of trust: compiler/selfhost/stage3.exe.c + any C compiler.
    if (-not (Test-Path "$RootDir\compiler\selfhost\stage3.exe.c")) {
        Write-Error "[ERROR] Canonical compiler C source not found at compiler\selfhost\stage3.exe.c."
    }
    $Py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $Py) { $Py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $Py) {
        Write-Error "[ERROR] Python is required to run the Zig-free bootstrap (scripts/build_selfhost.py)."
    }
    Write-Host "[*] Building self-hosted fixed-point compiler (no Zig involved)..." -ForegroundColor Yellow
    $buildArgs = @("$RootDir\scripts\build_selfhost.py", "--out", "$InstallDir\orbit.exe")
    if ($Cc) { $buildArgs += @("--cc", $Cc) }
    & $Py.Source @buildArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$InstallDir\orbit.exe")) {
        Write-Error "[ERROR] Self-hosted bootstrap failed. Set ORBIT_CC to your C compiler (gcc/clang/cc) and retry."
    }
    $SourceExe = "$InstallDir\orbit.exe"
    Write-Host "[+] Selected self-hosted fixed-point compiler: $SourceExe" -ForegroundColor Green
}

if ($SourceExe -ne "$InstallDir\orbit.exe") {
    Copy-Item -Path $SourceExe -Destination "$InstallDir\orbit.exe" -Force
}
Write-Host "[+] Installed Orbit binary to: $InstallDir\orbit.exe" -ForegroundColor Green

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
Write-Host " [SUCCESS] Orbit setup completed successfully!" -ForegroundColor Green
Write-Host " Restart your terminal and run 'orbit --help' or open VS Code." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
