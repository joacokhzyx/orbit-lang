$b = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_off = [BitConverter]::ToUInt32($b, 0x3C)
$num_secs = [BitConverter]::ToUInt16($b, $pe_off + 4 + 2)
$opt_sz = [BitConverter]::ToUInt16($b, $pe_off + 4 + 16)
$sec_off = $pe_off + 4 + 20 + $opt_sz

$opt_off = $pe_off + 4 + 20
$magic = [BitConverter]::ToUInt16($b, $opt_off)
$entry_point = [BitConverter]::ToUInt32($b, $opt_off + 16)
$base_code = [BitConverter]::ToUInt32($b, $opt_off + 20)
$image_base = [BitConverter]::ToUInt64($b, $opt_off + 24)
$sec_align = [BitConverter]::ToUInt32($b, $opt_off + 32)
$file_align = [BitConverter]::ToUInt32($b, $opt_off + 36)
$size_image = [BitConverter]::ToUInt32($b, $opt_off + 56)
$size_headers = [BitConverter]::ToUInt32($b, $opt_off + 60)
$subsystem = [BitConverter]::ToUInt16($b, $opt_off + 68)
$dll_chars = [BitConverter]::ToUInt16($b, $opt_off + 70)
$num_rva_sizes = [BitConverter]::ToUInt32($b, $opt_off + 108)

Write-Host "PE Offset: 0x$($pe_off.ToString('X'))"
Write-Host "Magic: 0x$($magic.ToString('X'))"
Write-Host "EntryPoint: 0x$($entry_point.ToString('X'))"
Write-Host "BaseOfCode: 0x$($base_code.ToString('X'))"
Write-Host "ImageBase: 0x$($image_base.ToString('X'))"
Write-Host "SectionAlignment: 0x$($sec_align.ToString('X'))"
Write-Host "FileAlignment: 0x$($file_align.ToString('X'))"
Write-Host "SizeOfImage: 0x$($size_image.ToString('X'))"
Write-Host "SizeOfHeaders: 0x$($size_headers.ToString('X'))"
Write-Host "Subsystem: $subsystem"
Write-Host "DllCharacteristics: 0x$($dll_chars.ToString('X'))"
Write-Host "NumberOfRvaAndSizes: $num_rva_sizes"

Write-Host "`nSections:"
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
