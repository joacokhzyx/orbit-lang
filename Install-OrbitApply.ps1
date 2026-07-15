#requires -Version 5.1
<#
.SYNOPSIS
    Instalador de 'orbit-apply': un aplicador de archivos atomico, verificado y
    con backups/rollback, pensado para reemplazar fuentes del repo Orbit a
    partir de un manifiesto comprimido en base64 (el "comando inline").

.DESCRIPTION
    Este script:
      1. Crea el directorio de instalacion (por defecto %LOCALAPPDATA%\OrbitApply).
      2. Escribe el programa 'orbit-apply.ps1'.
      3. Registra una funcion 'orbit-apply' en tu perfil de PowerShell para
         poder invocarla desde cualquier terminal.

    Uso posterior (el "comando inline" que te paso yo):
        orbit-apply -PayloadFile .\apply-fix-001.txt         # recomendado (payloads grandes)
        orbit-apply 'H4sIA....'                               # inline directo (payloads chicos)
        Get-Content .\apply-fix-001.txt -Raw | orbit-apply    # por stdin

    Modos utiles:
        orbit-apply -PayloadFile x.txt -DryRun    # valida y muestra el plan, no escribe
        orbit-apply -ListBackups                  # lista backups
        orbit-apply -Rollback <id>                # restaura un backup por id (timestamp)

.PARAMETER InstallDir
    Carpeta de instalacion. Por defecto: $env:LOCALAPPDATA\OrbitApply

.PARAMETER NoProfile
    No modifica el perfil de PowerShell (solo instala el .ps1).
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'OrbitApply'),
    [switch]$NoProfile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host '== Instalador de orbit-apply ==' -ForegroundColor Cyan

# ------------------------------------------------------------------
# 1) Crear directorio de instalacion
# ------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$toolPath = Join-Path $InstallDir 'orbit-apply.ps1'
Write-Host "Directorio: $InstallDir"

# ------------------------------------------------------------------
# 2) Contenido del programa orbit-apply.ps1 (literal, sin expandir)
# ------------------------------------------------------------------
$tool = @'
#requires -Version 5.1
<#
  orbit-apply : aplicador de archivos verificado con backup + rollback.

  Formato del manifiesto (JSON, comprimido gzip y luego base64):
    {
      "v": 1,
      "files": [
        { "path": "src/backend/lir/regalloc.zig", "sha256": "<hex>", "b64": "<base64 de los bytes crudos>" }
      ],
      "sha256": "<hex del checksum del manifiesto>"
    }

  Algoritmo (two-phase commit):
    A. Decodificar   : base64 -> gunzip -> UTF8 -> JSON.
    B. Validar TODO  : sha256 del manifiesto, sha256 por archivo, rutas seguras
                       (dentro de la raiz del repo, sin ".." ni rutas absolutas).
    C. Backup        : copiar los archivos existentes a
                       <root>\.orbit-apply\backups\<timestamp>\ + restore.json.
    D. Escribir      : bytes exactos (WriteAllBytes, sin BOM, sin tocar EOL) a
                       un temporal y luego Move-Item -Force (semi-atomico).
    E. Verificar     : releer y comparar sha256; si algo falla -> rollback total.
#>
[CmdletBinding(DefaultParameterSetName='Apply')]
param(
    [Parameter(Position=0, ParameterSetName='Apply')]
    [string]$Payload,
    [Parameter(ParameterSetName='Apply')]
    [string]$PayloadFile,
    [Parameter(ParameterSetName='Apply', ValueFromPipeline=$true)]
    [string]$PipedPayload,
    [Parameter(ParameterSetName='Apply')]
    [switch]$DryRun,
    [Parameter(ParameterSetName='Apply')]
    [switch]$Yes,
    [string]$Root,
    [Parameter(ParameterSetName='Rollback')]
    [string]$Rollback,
    [Parameter(ParameterSetName='List')]
    [switch]$ListBackups
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------- helpers ----------
function Get-Sha256Hex([byte[]]$bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) }
    finally { $sha.Dispose() }
}

function Expand-Gzip([byte[]]$bytes) {
    $inStream  = New-Object System.IO.MemoryStream(,$bytes)
    $gz        = New-Object System.IO.Compression.GZipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
    $outStream = New-Object System.IO.MemoryStream
    try { $gz.CopyTo($outStream); $outStream.ToArray() }
    finally { $gz.Dispose(); $inStream.Dispose(); $outStream.Dispose() }
}

function Find-RepoRoot([string]$start) {
    $dir = Get-Item -LiteralPath $start
    while ($null -ne $dir) {
        foreach ($marker in @("build.zig", ".git", "orbit.atlas")) {
            if (Test-Path -LiteralPath (Join-Path $dir.FullName $marker)) { return $dir.FullName }
        }
        $dir = $dir.Parent
    }
    return (Resolve-Path -LiteralPath $start).Path
}

function Resolve-Root {
    param([string]$Root)
    if ($Root) { return (Resolve-Path -LiteralPath $Root).Path }
    return (Find-RepoRoot (Get-Location).Path)
}

# ---------- modo: listar backups ----------
if ($PSCmdlet.ParameterSetName -eq "List") {
    $root = Resolve-Root -Root $Root
    $bdir = Join-Path $root ".orbit-apply\backups"
    if (-not (Test-Path -LiteralPath $bdir)) { Write-Host "No hay backups en $bdir"; return }
    Get-ChildItem -LiteralPath $bdir -Directory | Sort-Object Name | ForEach-Object {
        $rj = Join-Path $_.FullName "restore.json"
        $n  = if (Test-Path $rj) { (Get-Content $rj -Raw | ConvertFrom-Json).files.Count } else { "?" }
        Write-Host ("{0}  ({1} archivos)" -f $_.Name, $n)
    }
    return
}

# ---------- modo: rollback ----------
if ($PSCmdlet.ParameterSetName -eq "Rollback") {
    $root = Resolve-Root -Root $Root
    $set  = Join-Path $root (".orbit-apply\backups\" + $Rollback)
    $rj   = Join-Path $set "restore.json"
    if (-not (Test-Path -LiteralPath $rj)) { throw "No existe el backup '$Rollback' ($rj)" }
    $man = Get-Content $rj -Raw | ConvertFrom-Json
    foreach ($f in $man.files) {
        $target = Join-Path $root $f.path
        if ($f.existed) {
            $bak = Join-Path $set $f.backup
            Copy-Item -LiteralPath $bak -Destination $target -Force
            Write-Host ("restaurado  {0}" -f $f.path) -ForegroundColor Yellow
        } else {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
            Write-Host ("eliminado   {0} (no existia antes)" -f $f.path) -ForegroundColor Yellow
        }
    }
    Write-Host "Rollback completo." -ForegroundColor Green
    return
}

# ---------- modo: apply ----------
# Obtener el payload de: -Payload | -PayloadFile | stdin
if (-not $Payload) {
    if ($PayloadFile)        { $Payload = (Get-Content -LiteralPath $PayloadFile -Raw) }
    elseif ($PipedPayload)   { $Payload = $PipedPayload }
}
if (-not $Payload) { throw "Falta el payload. Usa -PayloadFile <archivo> o pasa el base64 como argumento." }
$Payload = ($Payload -replace "\s", "")   # tolerar saltos de linea / espacios pegados

$root = Resolve-Root -Root $Root
$rootFull = [System.IO.Path]::GetFullPath($root)
Write-Host "Repo root: $rootFull" -ForegroundColor Cyan

# A. decodificar
try {
    $gzBytes  = [Convert]::FromBase64String($Payload)
    $jsonBytes = Expand-Gzip $gzBytes
    $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
    $m = $json | ConvertFrom-Json
} catch { throw "Payload invalido (no es base64+gzip+json): $($_.Exception.Message)" }

if ($m.v -ne 1) { throw "Version de manifiesto no soportada: $($m.v)" }

# B. validar checksum del manifiesto
$canon = ""
foreach ($f in $m.files) { $canon += $f.path + "`n" + $f.sha256 + "`n" }
$calc = Get-Sha256Hex ([System.Text.Encoding]::UTF8.GetBytes($canon))
if ($calc -ne $m.sha256) { throw "Checksum del manifiesto no coincide (paste corrupto o truncado)." }

# B. validar cada archivo (todo antes de escribir nada)
$plan = @()
foreach ($f in $m.files) {
    if ([System.IO.Path]::IsPathRooted($f.path) -or $f.path -match '\.\.') {
        throw "Ruta no permitida: $($f.path)"
    }
    $bytes = [Convert]::FromBase64String($f.b64)
    $sha   = Get-Sha256Hex $bytes
    if ($sha -ne $f.sha256) { throw "sha256 no coincide para $($f.path)" }
    $target = [System.IO.Path]::GetFullPath((Join-Path $rootFull $f.path))
    if (-not $target.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "La ruta escapa del repo: $($f.path)"
    }
    $exists = Test-Path -LiteralPath $target
    $act = if ($exists) { "reemplaza" } else { "crea" }
    $plan += [pscustomobject]@{ path=$f.path; target=$target; bytes=$bytes; size=$bytes.Length; action=$act; existed=$exists }
}

# Mostrar plan
Write-Host "`nPlan:" -ForegroundColor Cyan
$plan | ForEach-Object { Write-Host ("  [{0,-9}] {1}  ({2} bytes)" -f $_.action, $_.path, $_.size) }

if ($DryRun) { Write-Host "`n(DryRun) No se escribio nada." -ForegroundColor Yellow; return }

if (-not $Yes) {
    $ans = Read-Host "`nAplicar estos cambios? (s/N)"
    if ($ans -notmatch '^(s|si|y|yes)$') { Write-Host "Cancelado."; return }
}

# C. backup
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$set   = Join-Path $rootFull (".orbit-apply\backups\" + $stamp)
New-Item -ItemType Directory -Path $set -Force | Out-Null
$restore = @{ stamp=$stamp; files=@() }
foreach ($p in $plan) {
    $entry = @{ path=$p.path; existed=$p.existed; backup=$null }
    if ($p.existed) {
        $flat = ($p.path -replace '[\\/:]', '__')
        $bak  = Join-Path $set $flat
        Copy-Item -LiteralPath $p.target -Destination $bak -Force
        $entry.backup = $flat
    }
    $restore.files += $entry
}
($restore | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $set "restore.json") -Encoding UTF8
Write-Host ("Backup: {0}" -f $set) -ForegroundColor DarkGray

# D. escribir (temp + move)
foreach ($p in $plan) {
    $dir = Split-Path -Parent $p.target
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $p.target + ".oatmp"
    [System.IO.File]::WriteAllBytes($tmp, $p.bytes)   # bytes exactos: sin BOM, EOL intactos
    Move-Item -LiteralPath $tmp -Destination $p.target -Force
}

# E. verificar; si algo falla -> rollback total
$bad = @()
foreach ($p in $plan) {
    $now = Get-Sha256Hex ([System.IO.File]::ReadAllBytes($p.target))
    $exp = Get-Sha256Hex $p.bytes
    if ($now -ne $exp) { $bad += $p.path }
}
if ($bad.Count -gt 0) {
    Write-Host "Verificacion fallida; haciendo rollback..." -ForegroundColor Red
    & $PSCommandPath -Rollback $stamp -Root $rootFull
    throw ("Escritura corrupta en: " + ($bad -join ", "))
}

Write-Host "`nOK. Archivos aplicados y verificados:" -ForegroundColor Green
$plan | ForEach-Object { Write-Host ("  {0}  ({1})" -f $_.path, $_.action) -ForegroundColor Green }
Write-Host ("Para revertir:  orbit-apply -Rollback {0}" -f $stamp) -ForegroundColor DarkGray
'@

Set-Content -LiteralPath $toolPath -Value $tool -Encoding UTF8
Write-Host "Programa escrito: $toolPath" -ForegroundColor Green

# ------------------------------------------------------------------
# 3) Registrar funcion en el perfil
# ------------------------------------------------------------------
if (-not $NoProfile) {
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir  = Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }

    $marker = '# >>> orbit-apply >>>'
    $endm   = '# <<< orbit-apply <<<'
    $block  = @"
$marker
function orbit-apply { & "$toolPath" @args }
$endm
"@
    $current = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $current) { $current = '' }
    if ($current -match [regex]::Escape($marker)) {
        $pattern = [regex]::Escape($marker) + '(?s).*?' + [regex]::Escape($endm)
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($mm) $block }
        $current = [regex]::Replace($current, $pattern, $evaluator)
        Set-Content -LiteralPath $profilePath -Value $current -Encoding UTF8
    } else {
        Add-Content -LiteralPath $profilePath -Value ("`r`n" + $block) -Encoding UTF8
    }
    Write-Host "Funcion 'orbit-apply' registrada en: $profilePath" -ForegroundColor Green
    Write-Host "Abri una terminal nueva (o corre: . `$PROFILE) para activarla." -ForegroundColor Yellow
}

Write-Host "`nListo. Probalo con:  orbit-apply -PayloadFile .\apply-fix-001.txt -DryRun" -ForegroundColor Cyan
