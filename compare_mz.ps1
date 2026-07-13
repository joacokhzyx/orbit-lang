$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")

Write-Host "MZ Header Comparison (first 64 bytes):"
for ($i = 0; $i -lt 64; $i += 16) {
    $h = ""
    $o = ""
    for ($j = 0; $j -lt 16; $j++) {
        $idx = $i + $j
        if ($idx -lt 64) {
            $h += "{0:X2} " -f $b_host[$idx]
            $o += "{0:X2} " -f $b_out[$idx]
        }
    }
    Write-Host ("  Host: {0} | Out: {1}" -f $h, $o)
}
