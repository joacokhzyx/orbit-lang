$b = [IO.File]::ReadAllBytes("C:\Users\Alumnos\AppData\Local\Temp\orbit\native_stub.obj")

# Parse COFF Header
$num_sections = [BitConverter]::ToUInt16($b, 2)
$sym_table_ptr = [BitConverter]::ToUInt32($b, 8)
$num_symbols = [BitConverter]::ToUInt32($b, 12)

Write-Host "COFF Object File Sections and Relocations:"
$sec_off = 20
for ($i = 0; $i -lt $num_sections; $i++) {
    $s = $sec_off + $i * 40
    $name = [System.Text.Encoding]::ASCII.GetString($b[$s..($s+7)]).TrimEnd([char]0)
    $num_relocs = [BitConverter]::ToUInt16($b, $s + 32)
    $relocs_ptr = [BitConverter]::ToUInt32($b, $s + 24)
    
    if ($num_relocs -gt 0) {
        Write-Host "  Section '$name' has $num_relocs relocations at file offset 0x$($relocs_ptr.ToString('X')):"
        
        for ($r = 0; $r -lt $num_relocs; $r++) {
            $ro = $relocs_ptr + $r * 10
            $r_type = [BitConverter]::ToUInt16($b, $ro + 8)
            Write-Host "    Reloc [$r]: Type=$r_type"
        }
    }
}
