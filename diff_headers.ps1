$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")

$pe_host = [BitConverter]::ToUInt32($b_host, 0x3C)
$pe_out = [BitConverter]::ToUInt32($b_out, 0x3C)

Write-Host "PE Header Host offset: 0x$($pe_host.ToString('X'))"
Write-Host "PE Header Out offset: 0x$($pe_out.ToString('X'))"

# Compare Optional Header fields at opt_off
# We will compare first 240 bytes of Optional Header (which is from opt_off to opt_off + 240)
$opt_host = $pe_host + 4 + 20
$opt_out = $pe_out + 4 + 20

Write-Host "`nComparing Optional Header bytes (Host vs Out):"
for ($i = 0; $i -lt 240; $i++) {
    $h = $b_host[$opt_host + $i]
    $o = $b_out[$opt_out + $i]
    if ($h -ne $o) {
        Write-Host ("  Offset {0,3} (0x{0:X2}): Host=0x{1:X2} | Out=0x{2:X2}" -f $i, $h, $o)
    }
}
