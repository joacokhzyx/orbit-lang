# Orbit Installer for Windows
# Installs Orbit Language Compiler and registers .orb file associations.

$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "         ⏣ ORBIT LANGUAGE INSTALLER ⏣" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Installing Orbit v0.1.0-rc.1 to your local system..." -ForegroundColor Yellow

$installRoot = Join-Path $HOME ".orbit"
$binDir = Join-Path $installRoot "bin"
$runtimeDir = Join-Path $installRoot "src\runtime"
$sqliteDir = Join-Path $installRoot "src\lib\sqlite"

# 1. Ensure directories exist
Write-Host "Creating installation folders..." -ForegroundColor Gray
New-Item -ItemType Directory -Path $binDir -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
New-Item -ItemType Directory -Path $sqliteDir -Force | Out-Null

# 2. Check and copy local binaries and sources
$localExe = "zig-out\bin\orbit_binary.exe"
if (-not (Test-Path $localExe)) {
    Write-Host "Building Orbit compiler using 'zig build' first..." -ForegroundColor Yellow
    & zig build
    if (-not (Test-Path $localExe)) {
        throw "Could not find built orbit.exe binary. Please make sure zig build succeeded."
    }
}

Write-Host "Copying compiler binary..." -ForegroundColor Gray
Copy-Item $localExe -Destination (Join-Path $binDir "orbit.exe") -Force

if (Test-Path "orbit.ico") {
    Write-Host "Copying Orbit file icon..." -ForegroundColor Gray
    Copy-Item "orbit.ico" -Destination (Join-Path $binDir "orbit.ico") -Force
}

Write-Host "Copying runtime headers and source files..." -ForegroundColor Gray
Copy-Item "src\runtime\*" -Destination $runtimeDir -Force -Recurse
Copy-Item "src\lib\sqlite\*" -Destination $sqliteDir -Force -Recurse

# 3. Add to PATH
Write-Host "Adding Orbit to User PATH..." -ForegroundColor Gray
$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentPath -split ";" -notcontains $binDir) {
    $newPath = $currentPath + ";" + $binDir
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path += ";$binDir"
    Write-Host "Added $binDir to your User PATH." -ForegroundColor Green
} else {
    Write-Host "Orbit PATH is already registered." -ForegroundColor Cyan
}

# 4. Registry File Association Helper
Function Set-RegistryDefaultValue($keyPath, $value) {
    if (-not (Test-Path $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }
    Set-Item -Path $keyPath -Value $value
}

Write-Host "Registering .orb file associations..." -ForegroundColor Gray
try {
    Set-RegistryDefaultValue "HKCU:\Software\Classes\.orb" "OrbitSourceFile"
    Set-RegistryDefaultValue "HKCU:\Software\Classes\OrbitSourceFile" "Orbit Language Source File"
    
    if (Test-Path (Join-Path $binDir "orbit.ico")) {
        Set-RegistryDefaultValue "HKCU:\Software\Classes\OrbitSourceFile\DefaultIcon" "$(Join-Path $binDir 'orbit.ico'),0"
    }
    
    Set-RegistryDefaultValue "HKCU:\Software\Classes\OrbitSourceFile\shell\open\command" "`"$(Join-Path $binDir 'orbit.exe')`" run `"%1`""
    Write-Host "Registered .orb files to run using orbit.exe." -ForegroundColor Green
} catch {
    Write-Warning "Could not register file associations in registry: $_"
}

Write-Host "==================================================" -ForegroundColor Green
Write-Host " ⏣ Orbit v0.1.0-rc.1 installed successfully!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "Installation path: $installRoot" -ForegroundColor Yellow
Write-Host ""
Write-Host "Please RESTART your terminal/editor to reload your PATH environment variable." -ForegroundColor Magenta
Write-Host "To test the installation, run:" -ForegroundColor Gray
Write-Host "    orbit run tests/bootstrap/fixtures/nested_call.orb" -ForegroundColor Cyan
Write-Host ""
