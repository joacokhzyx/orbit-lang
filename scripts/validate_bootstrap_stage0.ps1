param(
    [string]$Source = "compiler/main.orb",
    [string]$Endpoint = "http://127.0.0.1:3000/compile",
    [string]$ExpectedBody = "",
    [int]$StartupTimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host "[bootstrap] Building $Source"
& zig build run -- build $Source
if ($LASTEXITCODE -ne 0) {
    throw "Stage-0 build failed"
}

$serverExe = Join-Path $root "orbit.exe"
if (-not (Test-Path $serverExe)) {
    throw "orbit.exe was not generated"
}

$server = Start-Process -FilePath $serverExe -PassThru -WindowStyle Hidden

try {
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $ready = $false

    while ((Get-Date) -lt $deadline) {
        try {
            $probe = Invoke-WebRequest -Uri $Endpoint -Method GET -TimeoutSec 2
            if ($probe.StatusCode -eq 200) {
                $ready = $true
                break
            }
        }
        catch {
            # Retry until timeout
        }
        Start-Sleep -Milliseconds 300
    }

    if (-not $ready) {
        throw "Stage-0 server did not become ready at $Endpoint"
    }

    $response = Invoke-WebRequest -Uri $Endpoint -Method GET -TimeoutSec 5
    Write-Host "[bootstrap] Endpoint status: $($response.StatusCode)"
    Write-Host "[bootstrap] Endpoint body: $($response.Content)"

    if ($response.StatusCode -ne 200) {
        throw "Unexpected HTTP status code"
    }

    if ($ExpectedBody -ne "" -and $response.Content -ne $ExpectedBody) {
        throw "Unexpected response body. Expected '$ExpectedBody'"
    }

    Write-Host "[bootstrap] Stage-0 validation passed"
}
finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
    }
}
