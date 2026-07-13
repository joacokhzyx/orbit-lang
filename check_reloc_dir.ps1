$b = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe = [BitConverter]::ToUInt32($b, 0x3C)
$opt = $pe + 4 + 20
$reloc_dir_rva = [BitConverter]::ToUInt32($b, $opt + 152)
$reloc_dir_size = [BitConverter]::ToUInt32($b, $opt + 156)

Write-Host "Directory 5 (Base Relocation Table):"
Write-Host "  RVA:  0x$($reloc_dir_rva.ToString('X'))"
Write-Host "  Size: 0x$($reloc_dir_size.ToString('X'))"
