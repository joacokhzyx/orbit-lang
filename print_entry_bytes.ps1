$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_host = [BitConverter]::ToUInt32($b_host, 0x3C)
$entry_host = [BitConverter]::ToUInt32($b_host, $pe_host + 4 + 20 + 16)
# Convert EntryPoint RVA to File Offset for Host
# Find which section it belongs to
$sec_off_host = $pe_host + 4 + 20 + [BitConverter]::ToUInt16($b_host, $pe_host + 4 + 16)
$num_secs_host = [BitConverter]::ToUInt16($b_host, $pe_host + 4 + 2)
$file_off_host = 0
for ($i = 0; $i -lt $num_secs_host; $i++) {
    $s = $sec_off_host + $i * 40
    $va = [BitConverter]::ToUInt32($b_host, $s + 12)
    $vsz = [BitConverter]::ToUInt32($b_host, $s + 8)
    $raw_ptr = [BitConverter]::ToUInt32($b_host, $s + 20)
    if ($entry_host -ge $va -and $entry_host -lt ($va + $vsz)) {
        $file_off_host = $raw_ptr + ($entry_host - $va)
        break
    }
}

$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_out = [BitConverter]::ToUInt32($b_out, 0x3C)
$entry_out = [BitConverter]::ToUInt32($b_out, $pe_out + 4 + 20 + 16)
$sec_off_out = $pe_out + 4 + 20 + [BitConverter]::ToUInt16($b_out, $pe_out + 4 + 16)
$num_secs_out = [BitConverter]::ToUInt16($b_out, $pe_out + 4 + 2)
$file_off_out = 0
for ($i = 0; $i -lt $num_secs_out; $i++) {
    $s = $sec_off_out + $i * 40
    $va = [BitConverter]::ToUInt32($b_out, $s + 12)
    $vsz = [BitConverter]::ToUInt32($b_out, $s + 8)
    $raw_ptr = [BitConverter]::ToUInt32($b_out, $s + 20)
    if ($entry_out -ge $va -and $entry_out -lt ($va + $vsz)) {
        $file_off_out = $raw_ptr + ($entry_out - $va)
        break
    }
}

Write-Host "Host EntryPoint RVA=0x$($entry_host.ToString('X')), FileOffset=0x$($file_off_host.ToString('X'))"
$h_bytes = ""
for ($k = 0; $k -lt 16; $k++) {
    $h_bytes += "{0:X2} " -f $b_host[$file_off_host + $k]
}
Write-Host "Host Bytes: $h_bytes"

Write-Host "`nOut EntryPoint RVA=0x$($entry_out.ToString('X')), FileOffset=0x$($file_off_out.ToString('X'))"
$o_bytes = ""
for ($k = 0; $k -lt 16; $k++) {
    $o_bytes += "{0:X2} " -f $b_out[$file_off_out + $k]
}
Write-Host "Out Bytes:  $o_bytes"
