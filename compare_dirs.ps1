$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_off_host = [BitConverter]::ToUInt32($b_host, 0x3C)
$opt_off_host = $pe_off_host + 4 + 20
$dirs_off_host = $opt_off_host + 112

$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_off_out = [BitConverter]::ToUInt32($b_out, 0x3C)
$opt_off_out = $pe_off_out + 4 + 20
$dirs_off_out = $opt_off_out + 112

$dir_names = @(
    "Export Table", "Import Table", "Resource Table", "Exception Table",
    "Certificate Table", "Base Relocation Table", "Debug Directory", "Architecture Specific",
    "Global Pointer", "Thread Local Storage", "Load Config", "Bound Import Table",
    "Import Address Table", "Delay Import Descriptor", "CLR Runtime Header", "Reserved"
)

Write-Host "Data Directories Comparison:"
for ($i = 0; $i -lt 16; $i++) {
    $off = $i * 8
    
    $rva_host = [BitConverter]::ToUInt32($b_host, $dirs_off_host + $off)
    $sz_host = [BitConverter]::ToUInt32($b_host, $dirs_off_host + $off + 4)
    
    $rva_out = [BitConverter]::ToUInt32($b_out, $dirs_off_out + $off)
    $sz_out = [BitConverter]::ToUInt32($b_out, $dirs_off_out + $off + 4)
    
    Write-Host ("  {0,-25}: Host=(RVA=0x{1:X}, Size=0x{2:X}) | Out=(RVA=0x{3:X}, Size=0x{4:X})" -f $dir_names[$i], $rva_host, $sz_host, $rva_out, $sz_out)
}
