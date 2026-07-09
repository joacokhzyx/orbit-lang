param(
    [string]$ScenarioPath = "benchmarks/scenarios/professional-baseline.json",
    [string]$OrbitSource = "benchmarks/targets/http_benchmark.orb",
    [string]$ResultsRoot = "benchmarks/results",
    [switch]$SkipBuild,
    [switch]$SkipRust,
    [switch]$SkipCpp,
    [switch]$SkipGo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$benchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $benchRoot
Set-Location $repoRoot

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Wait-OrbitReady {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 45
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method GET -TimeoutSec 2
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return $true
            }
        }
        catch {
            # Retry until timeout.
        }

        Start-Sleep -Milliseconds 400
    }

    return $false
}

function Invoke-BenchmarkCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Write-Host "[run] $Label"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Benchmark command failed: $Label"
    }
}

function Write-EnvironmentSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $osInfo = $null
    $cpuInfo = $null
    try {
        $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cpuInfo = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        # Best effort snapshot.
    }

    $gitCommit = "unknown"
    try {
        $gitCommit = (& git rev-parse HEAD).Trim()
    }
    catch {
        # Best effort snapshot.
    }

    $toolVersions = [ordered]@{}
    foreach ($tool in @("zig", "rustc", "cargo", "go")) {
        if (Test-CommandAvailable $tool) {
            try {
                $versionLine = switch ($tool) {
                    "zig" { (& zig version | Select-Object -First 1) }
                    "rustc" { (& rustc --version | Select-Object -First 1) }
                    "cargo" { (& cargo --version | Select-Object -First 1) }
                    "go" { (& go version | Select-Object -First 1) }
                }
                $toolVersions[$tool] = [string]$versionLine
            }
            catch {
                $toolVersions[$tool] = "available"
            }
        }
        else {
            $toolVersions[$tool] = "missing"
        }
    }

    $snapshot = [ordered]@{
        captured_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        repository = "orbit-binary"
        git_commit = $gitCommit
        host = [ordered]@{
            machine_name = $env:COMPUTERNAME
            os_caption = if ($null -ne $osInfo) { [string]$osInfo.Caption } else { "unknown" }
            os_version = if ($null -ne $osInfo) { [string]$osInfo.Version } else { "unknown" }
            cpu_name = if ($null -ne $cpuInfo) { [string]$cpuInfo.Name } else { "unknown" }
            cpu_cores = if ($null -ne $cpuInfo) { [int]$cpuInfo.NumberOfCores } else { 0 }
            cpu_logical = if ($null -ne $cpuInfo) { [int]$cpuInfo.NumberOfLogicalProcessors } else { 0 }
            total_memory_gb = if ($null -ne $osInfo) { [math]::Round(([double]$osInfo.TotalVisibleMemorySize / 1MB), 2) } else { 0 }
        }
        tool_versions = $toolVersions
    }

    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
}

if (-not (Test-Path $ScenarioPath)) {
    throw "Scenario file not found: $ScenarioPath"
}

$scenario = Get-Content $ScenarioPath -Raw | ConvertFrom-Json

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $ResultsRoot $runId
New-Item -Path $runDir -ItemType Directory -Force | Out-Null

Write-Host "[info] Benchmark run: $runId"
Write-Host "[info] Scenario: $($scenario.name)"
Write-Host "[info] Output: $runDir"

$environmentPath = Join-Path $runDir "environment.json"
Write-EnvironmentSnapshot -OutputPath $environmentPath
Write-Host "[info] Environment snapshot: $environmentPath"

$rustAvailable = (Test-CommandAvailable cargo)
$goAvailable = (Test-CommandAvailable go)
$zigAvailable = (Test-CommandAvailable zig)
$isWindowsHost = $env:OS -eq "Windows_NT"

$runRust = -not [bool]$SkipRust
$runCpp = -not [bool]$SkipCpp
$runGo = -not [bool]$SkipGo

if ($runRust -and $rustAvailable) {
    $rustHostLine = & rustc -vV | Where-Object { $_ -like "host:*" }
    $rustHost = if ($null -ne $rustHostLine) { ($rustHostLine -split ":")[1].Trim() } else { "" }

    if ($rustHost -like "*windows-msvc*" -and -not (Test-CommandAvailable "link.exe")) {
        Write-Warning "Skipping Rust benchmark because rust host '$rustHost' requires link.exe (MSVC Build Tools)"
        $runRust = $false
    }
}

if (-not $SkipBuild) {
    if (-not $zigAvailable) {
        throw "zig is required to build Orbit target"
    }

    Write-Host "[build] Orbit target: $OrbitSource"
    & zig build run -- build $OrbitSource
    if ($LASTEXITCODE -ne 0) {
        throw "Orbit build failed"
    }
}

$serverExe = Join-Path $repoRoot "orbit.exe"
if (-not (Test-Path $serverExe)) {
    throw "Expected server binary not found: $serverExe"
}

$serverProcess = Start-Process -FilePath $serverExe -PassThru -WindowStyle Hidden

$cppRunnerExe = Join-Path $repoRoot "benchmarks/clients/cpp/runner_cpp.exe"
$goRunnerExe = Join-Path $repoRoot "benchmarks/clients/go/runner_go.exe"

try {
    if (-not (Wait-OrbitReady -Url $scenario.url)) {
        throw "Orbit server did not become ready on $($scenario.url)"
    }

    if ($scenario.warmup_seconds -gt 0) {
        Write-Host "[warmup] $($scenario.warmup_seconds)s"
        $warmupDeadline = (Get-Date).AddSeconds([int]$scenario.warmup_seconds)
        while ((Get-Date) -lt $warmupDeadline) {
            try {
                Invoke-WebRequest -Uri $scenario.url -Method GET -TimeoutSec 2 | Out-Null
            }
            catch {
                # Ignore warmup errors.
            }
            Start-Sleep -Milliseconds 20
        }
    }

    if ($runCpp) {
        if (-not $zigAvailable) {
            Write-Warning "Skipping C++ benchmark because zig is unavailable"
            $runCpp = $false
        }
        else {
            Write-Host "[build] C++ runner (zig c++)"
            if ($isWindowsHost) {
                & zig c++ -std=c++17 -O2 -Wno-nullability-completeness -pthread benchmarks/clients/cpp/main.cpp -o benchmarks/clients/cpp/runner_cpp.exe -lws2_32
            }
            else {
                & zig c++ -std=c++17 -O2 -Wno-nullability-completeness -pthread benchmarks/clients/cpp/main.cpp -o benchmarks/clients/cpp/runner_cpp
                $cppRunnerExe = Join-Path $repoRoot "benchmarks/clients/cpp/runner_cpp"
            }

            if ($LASTEXITCODE -ne 0) {
                throw "C++ runner compilation failed"
            }
        }
    }

    if ($runGo) {
        if (-not $goAvailable) {
            Write-Warning "Skipping Go benchmark because go is unavailable"
            $runGo = $false
        }
        else {
            Write-Host "[build] Go runner"
            if ($isWindowsHost) {
                & go build -o $goRunnerExe benchmarks/clients/go/main.go
            }
            else {
                $goRunnerExe = Join-Path $repoRoot "benchmarks/clients/go/runner_go"
                & go build -o $goRunnerExe benchmarks/clients/go/main.go
            }

            if ($LASTEXITCODE -ne 0) {
                throw "Go runner compilation failed"
            }
        }
    }

    $concurrencyValues = @($scenario.concurrency)

    foreach ($c in $concurrencyValues) {
        $durationText = [int]$scenario.test_seconds
        $timeoutText = [int]$scenario.timeout_ms
        $concText = [int]$c

        if ($runRust) {
            if (-not $rustAvailable) {
                Write-Warning "Skipping Rust benchmark because cargo is unavailable"
                $runRust = $false
            }
            else {
                $rustOut = Join-Path $runDir ("rust-c{0}.json" -f $concText)
                Invoke-BenchmarkCommand -Label ("rust c={0}" -f $concText) -FilePath "cargo" -Arguments @(
                    "run",
                    "--manifest-path", "benchmarks/clients/rust/Cargo.toml",
                    "--release",
                    "--",
                    "--url", $scenario.url,
                    "--duration-seconds", "$durationText",
                    "--concurrency", "$concText",
                    "--timeout-ms", "$timeoutText",
                    "--out", $rustOut
                )
            }
        }

        if ($runCpp) {
            $cppOut = Join-Path $runDir ("cpp-c{0}.json" -f $concText)
            Invoke-BenchmarkCommand -Label ("cpp c={0}" -f $concText) -FilePath $cppRunnerExe -Arguments @(
                "--url", $scenario.url,
                "--duration-seconds", "$durationText",
                "--concurrency", "$concText",
                "--timeout-ms", "$timeoutText",
                "--out", $cppOut
            )
        }

        if ($runGo) {
            $goOut = Join-Path $runDir ("go-c{0}.json" -f $concText)
            Invoke-BenchmarkCommand -Label ("go c={0}" -f $concText) -FilePath $goRunnerExe -Arguments @(
                "--url", $scenario.url,
                "--duration-seconds", "$durationText",
                "--concurrency", "$concText",
                "--timeout-ms", "$timeoutText",
                "--out", $goOut
            )
        }
    }
}
finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
    }
}

$resultFiles = Get-ChildItem -Path $runDir -Filter *.json -File |
    Where-Object { $_.Name -match '^(rust|cpp|go)-c\d+\.json$' }
if ($resultFiles.Count -eq 0) {
    throw "No benchmark result JSON files were generated"
}

$rows = @()
foreach ($file in $resultFiles) {
    $row = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $rows += [PSCustomObject]@{
        runner = [string]$row.runner
        concurrency = [int]$row.concurrency
        requests_total = [int64]$row.requests_total
        success_total = [int64]$row.success_total
        error_total = [int64]$row.error_total
        error_rate_pct = [double]$row.error_rate_pct
        throughput_rps = [double]$row.throughput_rps
        latency_ms_p50 = [double]$row.latency_ms.p50
        latency_ms_p90 = [double]$row.latency_ms.p90
        latency_ms_p99 = [double]$row.latency_ms.p99
        latency_ms_max = [double]$row.latency_ms.max
        result_file = [string]$file.Name
    }
}

$rows = $rows | Sort-Object runner, concurrency
$summaryCsv = Join-Path $runDir "summary.csv"
$rows | Export-Csv -Path $summaryCsv -NoTypeInformation

$limits = $scenario.stress_failure_criteria
$stressRows = @()
foreach ($group in ($rows | Group-Object runner)) {
    $stable = @($group.Group |
        Sort-Object concurrency |
        Where-Object {
            $_.error_rate_pct -le [double]$limits.max_error_rate_pct -and
            $_.latency_ms_p99 -le [double]$limits.max_p99_ms
        })

    $maxStable = if ($stable.Count -gt 0) {
        [int](($stable | Select-Object -Last 1).concurrency)
    }
    else {
        0
    }

    $stressRows += [PSCustomObject]@{
        runner = [string]$group.Name
        max_stable_concurrency = $maxStable
        threshold_error_rate_pct = [double]$limits.max_error_rate_pct
        threshold_p99_ms = [double]$limits.max_p99_ms
    }
}

$stressCsv = Join-Path $runDir "stress-points.csv"
$stressRows | Export-Csv -Path $stressCsv -NoTypeInformation

Write-Host "[done] summary: $summaryCsv"
Write-Host "[done] stress points: $stressCsv"
