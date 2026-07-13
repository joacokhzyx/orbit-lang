$b = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_off = [BitConverter]::ToUInt32($b, 0x3C)
$num_secs = [BitConverter]::ToUInt16($b, $pe_off + 4 + 2)
$opt_sz = [BitConverter]::ToUInt16($b, $pe_off + 4 + 16)
$sec_off = $pe_off + 4 + 20 + $opt_sz

Write-Host "smoke_host.exe Sections:"
for ($i = 0; $i -lt $num_secs; $i++) {
    $s = $sec_off + $i * 40
    $name_bytes = New-Object byte[] 8
    [Array]::Copy($b, $s, $name_bytes, 0, 8)
    $name = [System.Text.Encoding]::ASCII.GetString($name_bytes).TrimEnd([char]0)
    $vsz = [BitConverter]::ToUInt32($b, $s + 8)
    $va = [BitConverter]::ToUInt32($b, $s + 12)
    $raw_sz = [BitConverter]::ToUInt32($b, $s + 16)
    $raw_ptr = [BitConverter]::ToUInt32($b, $s + 20)
    $chars = [BitConverter]::ToUInt32($b, $s + 36)
    Write-Host ("  [{0}] '{1}' VA=0x{2:X8} VSZ=0x{3:X4} RawSz=0x{4:X4} RawPtr=0x{5:X4} Chars=0x{6:X8}" -f $i, $name, $va, $vsz, $raw_sz, $raw_ptr, $chars)
}
