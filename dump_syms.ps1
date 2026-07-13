$path = "C:\Users\Alumnos\AppData\Local\Temp\orbit\native_stub.obj"
if (!(Test-Path $path)) {
    Write-Host "File not found: $path"
    exit
}

$b = [IO.File]::ReadAllBytes($path)
$num_syms = [BitConverter]::ToUInt32($b, 12)
$sym_table_off = [BitConverter]::ToUInt32($b, 8)
$str_table_off = $sym_table_off + $num_syms * 18

Write-Host "SymTable offset: 0x$($sym_table_off.ToString('X')), count: $num_syms"
Write-Host "StringTable offset: 0x$($str_table_off.ToString('X'))"

$i = 0
while ($i -lt $num_syms) {
    $sym_off = $sym_table_off + $i * 18
    if ($sym_off + 18 -gt $b.Length) {
        break
    }

    $name = ""
    # Check if string table reference
    if ($b[$sym_off] -eq 0 -and $b[$sym_off+1] -eq 0 -and $b[$sym_off+2] -eq 0 -and $b[$sym_off+3] -eq 0) {
        $str_off = [BitConverter]::ToUInt32($b, $sym_off + 4)
        $abs_off = $str_table_off + $str_off
        if ($abs_off -lt $b.Length) {
            $p = $abs_off
            while ($p -lt $b.Length -and $b[$p] -ne 0) {
                $name += [char]$b[$p]
                $p++
            }
        } else {
            $name = "(invalid)"
        }
    } else {
        # Inline name
        for ($k = 0; $k -lt 8; $k++) {
            $char = $b[$sym_off + $k]
            if ($char -eq 0) { break }
            $name += [char]$char
        }
    }

    $sec_num = [BitConverter]::ToInt16($b, $sym_off + 12)
    $sym_class = $b[$sym_off + 16]
    $aux_count = $b[$sym_off + 17]

    # Print all symbols
    Write-Host ("  sym[{0}] '{1}' sec={2} class={3} aux={4}" -f $i, $name, $sec_num, $sym_class, $aux_count)

    $i += 1 + $aux_count
}
