$b = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_off = [BitConverter]::ToUInt32($b, 0x3C)
$num_secs = [BitConverter]::ToUInt16($b, $pe_off + 4 + 2)
$opt_sz = [BitConverter]::ToUInt16($b, $pe_off + 4 + 16)
$sec_off = $pe_off + 4 + 20 + $opt_sz

Write-Host "Verifying smoke_out.exe raw layout:"
for ($i = 0; $i -lt $num_secs; $i++) {
    $s = $sec_off + $i * 40
    $name_bytes = New-Object byte[] 8
    [Array]::Copy($b, $s, $name_bytes, 0, 8)
    $name = [System.Text.Encoding]::ASCII.GetString($name_bytes).TrimEnd([char]0)
    $vsz = [BitConverter]::ToUInt32($b, $s + 8)
    $va = [BitConverter]::ToUInt32($b, $s + 12)
    $raw_sz = [BitConverter]::ToUInt32($b, $s + 16)
    $raw_ptr = [BitConverter]::ToUInt32($b, $s + 20)

    Write-Host "Section '$name':"
    Write-Host "  VA: 0x$($va.ToString('X')), VirtualSize: 0x$($vsz.ToString('X'))"
    Write-Host "  RawPtr: 0x$($raw_ptr.ToString('X')), RawSize: 0x$($raw_sz.ToString('X'))"
    
    if ($raw_sz -gt 0) {
        if ($raw_ptr + $raw_sz -gt $b.Length) {
            Write-Host "  ERROR: Section raw data extends beyond file length!" -ForegroundColor Red
        } else {
            # Check if all zeros or has content
            $has_content = $false
            for ($k = 0; $k -lt $raw_sz; $k++) {
                if ($b[$raw_ptr + $k] -ne 0) {
                    $has_content = $true
                    break
                }
            }
            Write-Host "  Has non-zero content: $has_content"
        }
    }
}
Write-Host "File Length: $($b.Length)"
