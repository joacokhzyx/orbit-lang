$path_stub = "C:\Users\Alumnos\AppData\Local\Temp\orbit\native_stub.obj"
$path_obj = "C:\Users\Alumnos\.orbit\cache\cache_smoke_orbit_7951918791260674867.exe.o"

function PrintRelocs($path, $label) {
    if (!(Test-Path $path)) {
        Write-Host "$label file not found: $path"
        return
    }
    $b = [IO.File]::ReadAllBytes($path)
    $num_secs = [BitConverter]::ToUInt16($b, 2)
    $sec_off = 20
    Write-Host "`nRelocations in $label ($num_secs sections):"
    for ($i = 0; $i -lt $num_secs; $i++) {
        $s = $sec_off + $i * 40
        $name = [System.Text.Encoding]::ASCII.GetString($b[$s..($s+7)]).TrimEnd([char]0)
        $rel_ptr = [BitConverter]::ToUInt32($b, $s + 24)
        $rel_cnt = [BitConverter]::ToUInt16($b, $s + 32)
        if ($rel_cnt -gt 0) {
            Write-Host "  Section $name Rels count: $rel_cnt at 0x$($rel_ptr.ToString('X'))"
            for ($r = 0; $r -lt $rel_cnt; $r++) {
                $ro = $rel_ptr + $r * 10
                $vaddr = [BitConverter]::ToUInt32($b, $ro)
                $sym_idx = [BitConverter]::ToUInt32($b, $ro + 4)
                $type = [BitConverter]::ToUInt16($b, $ro + 8)
                Write-Host "    rel[$r] vaddr=0x$($vaddr.ToString('X')) sym=$sym_idx type=$type"
            }
        }
    }
}

PrintRelocs $path_stub "native_stub"
PrintRelocs $path_obj "smoke_orbit"
