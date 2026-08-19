param(
    [string]$Stage = "C:\Users\Alumnos\Downloads\orbit\orbit-binary\compiler\selfhost\stage3.exe",
    [string]$Front = "C:\Users\Alumnos\Downloads\orbit\orbit-binary\zig-out\bin\orbit.exe",
    [string]$ProbeDir = "C:\Users\Alumnos\Downloads\orbit\orbit-binary\tests\parity\probes",
    [string]$OutDir = "C:\Users\Alumnos\AppData\Local\Temp\opencode\matriz"
)

# Orbit selfhost/FE parity gate (W1). Byte-identity contract:
#   both exit 0   -> generated C must be byte-identical
#   both exit !=0 -> captured stderr must be byte-identical
#   any other combo -> FAIL

$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$shTmp = Join-Path $OutDir "_sh"
$feTmp = Join-Path $OutDir "_fe"
New-Item -ItemType Directory -Force -Path $shTmp, $feTmp | Out-Null

$cOk = 0; $diagOk = 0; $fail = 0; $total = 0
$bad = @()

foreach ($p in Get-ChildItem $ProbeDir -Filter *.orb | Sort-Object Name) {
    $name = $p.BaseName
    $total++
    $shC = Join-Path $OutDir ($name + "_v.c")
    $feC = Join-Path $OutDir ($name + "_fe.c")
    $shLog = Join-Path $OutDir ($name + "_sh.log")
    $feLog = Join-Path $OutDir ($name + "_fe.log")

    cmd /c "rd /s /q `"$shTmp`" 2>nul"
    cmd /c "rd /s /q `"$feTmp`" 2>nul"
    New-Item -ItemType Directory -Force -Path $shTmp, $feTmp | Out-Null

    $env:TEMP = $shTmp; $env:TMP = $shTmp
    & $Stage $p.FullName -o (Join-Path $shTmp ($name + "_sh.exe")) *> $shLog 2>&1
    $shExit = $LASTEXITCODE
    if (Test-Path (Join-Path $shTmp "orbit_selfhost_build.c")) {
        Copy-Item (Join-Path $shTmp "orbit_selfhost_build.c") $shC -Force
    }

    cmd /c "rd /s /q `"$shTmp`" 2>nul"
    cmd /c "rd /s /q `"$feTmp`" 2>nul"
    New-Item -ItemType Directory -Force -Path $shTmp, $feTmp | Out-Null

    $env:TEMP = $feTmp; $env:TMP = $feTmp
    & $Front build $p.FullName -o (Join-Path $OutDir ($name + "_fe.exe")) *> $feLog 2>&1
    $feExit = $LASTEXITCODE
    $feC2 = Join-Path $feTmp "orbit\temp_build.c"
    if (Test-Path (Join-Path $feTmp "orbit_selfhost_build.c")) { $feC2 = Join-Path $feTmp "orbit_selfhost_build.c" }
    if (Test-Path $feC2) { Copy-Item $feC2 $feC -Force }

    Remove-Item Env:TEMP -ErrorAction SilentlyContinue; Remove-Item Env:TMP -ErrorAction SilentlyContinue

    $shHash = if (Test-Path $shC) { (Get-FileHash $shC -Algorithm SHA256).Hash } else { "NOC" }
    $feHash = if (Test-Path $feC) { (Get-FileHash $feC -Algorithm SHA256).Hash } else { "NOC" }

    if ($shExit -eq 0 -and $feExit -eq 0) {
        if ($shHash -eq $feHash -and $shHash -ne "NOC") { $cOk++; Write-Output ("{0,-24} C-IDENTICAL" -f $name) }
        else { $fail++; $bad += $name; Write-Output ("{0,-24} C-DIFF" -f $name) }
    }
    elseif ($shExit -ne 0 -and $feExit -ne 0) {
        $shText = (Get-Content $shLog -Raw -ErrorAction SilentlyContinue)
        $feText = (Get-Content $feLog -Raw -ErrorAction SilentlyContinue)
        if ($shText -eq $feText) { $diagOk++; Write-Output ("{0,-24} DIAG-IDENTICAL" -f $name) }
        else { $fail++; $bad += $name; Write-Output ("{0,-24} DIAG-DIFF" -f $name) }
    }
    else {
        $fail++; $bad += $name; Write-Output ("{0,-24} EXIT-MISMATCH(fe={1} sh={2})" -f $name, $feExit, $shExit)
    }
}

Write-Output ("RESULT: {0}/{1} identical (C={2} diag={3} fail={4})" -f ($cOk + $diagOk), $total, $cOk, $diagOk, $fail)
if ($fail -ne 0) { Write-Output ("FAILED: " + ($bad -join ", ")); exit 1 }
exit 0