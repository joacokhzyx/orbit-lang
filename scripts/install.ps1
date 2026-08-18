# Orbit Programming Language Automated Windows Installer
# Installs Orbit self-hosted or bootstrap compiler binary, configures PATH, and registers VS Code Extension.

param (
    [switch]$SelfHost = $true,
    [switch]$Bootstrap = $false
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

$BootstrapExe = "$RootDir\zig-out\bin\orbit.exe"
if (-not (Test-Path $BootstrapExe)) {
    Write-Host "[*] Compiling Orbit bootstrap compiler with ReleaseFast optimization..." -ForegroundColor Yellow
    zig build -Doptimize=ReleaseFast
    if (-not (Test-Path $BootstrapExe)) {
        Write-Error "[ERROR] Bootstrap compiler not found at $BootstrapExe. Did 'zig build' succeed?"
    }
}

$SourceExe = $BootstrapExe

# 2a. Prefer a pre-built fixed-point compiler shipped with a release.
$FixedPoint = "$RootDir\dist\orbit-windows-x86_64.exe"
if ($SelfHost -and (-not $Bootstrap) -and (Test-Path $FixedPoint)) {
    $SourceExe = $FixedPoint
    Write-Host "[+] Selected released fixed-point compiler: $SourceExe" -ForegroundColor Green
}
elseif ($SelfHost -and (-not $Bootstrap)) {
    # 2b. Pure self-hosted seed chain: canonical C -> seed -> seed2 -> chain2 -> chain3.
    $SeedExe = "$RootDir\dist\orbit_seed.exe"
    $ChainTmp = "$RootDir\dist\.chain_tmp"
    if (-not (Test-Path $SeedExe)) {
        Write-Host "[*] Building bootstrap seed from canonical C (dist/orbit_bootstrap.c)..." -ForegroundColor Yellow
        if (Test-Path "$RootDir\scripts\build_seed.bat") {
            Push-Location $RootDir
            try { & "$RootDir\scripts\build_seed.bat" } catch { }
            Pop-Location
        }
    }
    if (Test-Path $SeedExe) {
        Write-Host "[*] Building self-hosted seed chain (seed -> seed2 -> chain2 -> chain3)..." -ForegroundColor Yellow
        if (-not (Test-Path $ChainTmp)) { New-Item -ItemType Directory -Path $ChainTmp -Force | Out-Null }
        function Build-Orb {
            param([string]$Compiler, [string]$OutPath)
            $env:TEMP = $ChainTmp; $env:TMP = $ChainTmp
            & $Compiler build "$RootDir\compiler\main.orb" -o $OutPath
            if ($LASTEXITCODE -ne 0) { throw "orbit build failed: $Compiler -> $OutPath (exit $LASTEXITCODE)" }
        }
        try {
            Build-Orb $SeedExe "$RootDir\dist\orbit_seed2.exe"
            Build-Orb "$RootDir\dist\orbit_seed2.exe" "$RootDir\dist\orbit_chain2.exe"
            Build-Orb "$RootDir\dist\orbit_chain2.exe" "$RootDir\dist\orbit_chain3.exe"
            Remove-Item Env:TEMP -ErrorAction SilentlyContinue; Remove-Item Env:TMP -ErrorAction SilentlyContinue
            $SourceExe = "$RootDir\dist\orbit_chain3.exe"
            Write-Host "[+] Selected self-hosted fixed-point compiler (chain3): $SourceExe" -ForegroundColor Green
        } catch {
            Write-Host "[!] Seed chain build failed: $($_.Exception.Message). Falling back to Zig bootstrap." -ForegroundColor Yellow
        }
    }
    # 2c. Zig bootstrap fallback: use the self-hosted stage fixed point (stage3), not stage1.
    if ($SourceExe -eq $BootstrapExe) {
        Write-Host "[*] Building self-hosted compiler via Zig bootstrap (stage chain)..." -ForegroundColor Yellow
        try {
            & $BootstrapExe bootstrap
            $SelfHostStage3 = "$RootDir\compiler\selfhost\stage3.exe"
            if (Test-Path $SelfHostStage3) {
                $SourceExe = $SelfHostStage3
                Write-Host "[+] Selected self-hosted fixed-point compiler: $SourceExe" -ForegroundColor Green
            }
        } catch {
            Write-Host "[!] Self-hosted build fallback to bootstrap compiler." -ForegroundColor Yellow
        }
    }
}

$DestExe = "$InstallDir\orbit.exe"
Copy-Item -Path $SourceExe -Destination $DestExe -Force
Write-Host "[+] Installed Orbit binary ($SourceExe) to: $DestExe" -ForegroundColor Green

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
