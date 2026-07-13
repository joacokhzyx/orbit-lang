$b = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe = [BitConverter]::ToUInt32($b, 0x3C)
$opt = $pe + 4 + 20
$import_dir_rva = [BitConverter]::ToUInt32($b, $opt + 120)
$import_dir_size = [BitConverter]::ToUInt32($b, $opt + 124)

Write-Host "Import Directory RVA: 0x$($import_dir_rva.ToString('X')), Size: 0x$($import_dir_size.ToString('X'))"

# Find .idata section raw offset
$sec_off = $pe + 4 + 20 + [BitConverter]::ToUInt16($b, $pe + 4 + 16)
$num_secs = [BitConverter]::ToUInt16($b, $pe + 4 + 2)
$idata_raw = 0
$idata_va = 0
for ($i = 0; $i -lt $num_secs; $i++) {
    $s = $sec_off + $i * 40
    $name = [System.Text.Encoding]::ASCII.GetString($b[$s..($s+7)]).TrimEnd([char]0)
    if ($name -eq ".idata") {
        $idata_raw = [BitConverter]::ToUInt32($b, $s + 20)
        $idata_va = [BitConverter]::ToUInt32($b, $s + 12)
        break
    }
}

if ($idata_raw -eq 0) {
    Write-Host "No .idata section found"
    exit
}

# RVA to file offset helper
function RvaToOffset($rva, $sec_va, $sec_raw) {
    return $sec_raw + ($rva - $sec_va)
}

$dir_offset = RvaToOffset $import_dir_rva $idata_va $idata_raw
Write-Host "Import Directory File Offset: 0x$($dir_offset.ToString('X'))"

# Read descriptors
$idx = 0
while ($true) {
    $o = $dir_offset + $idx * 20
    $ilt_rva = [BitConverter]::ToUInt32($b, $o)
    $timedate = [BitConverter]::ToUInt32($b, $o + 4)
    $forwarder = [BitConverter]::ToUInt32($b, $o + 8)
    $name_rva = [BitConverter]::ToUInt32($b, $o + 12)
    $iat_rva = [BitConverter]::ToUInt32($b, $o + 16)
    
    if ($ilt_rva -eq 0 -and $name_rva -eq 0 -and $iat_rva -eq 0) {
        Write-Host "  Descriptor [$idx]: NULL (Terminator)"
        break
    }
    
    # Get DLL name
    $name_off = RvaToOffset $name_rva $idata_va $idata_raw
    $dll_name = ""
    $k = 0
    while ($b[$name_off + $k] -ne 0) {
        $dll_name += [char]$b[$name_off + $k]
        $k++
    }
    
    Write-Host "  Descriptor [$idx]: DLL='$dll_name'"
    Write-Host "    ILT RVA: 0x$($ilt_rva.ToString('X')) (FileOffset=0x$((RvaToOffset $ilt_rva $idata_va $idata_raw).ToString('X')))"
    Write-Host "    IAT RVA: 0x$($iat_rva.ToString('X')) (FileOffset=0x$((RvaToOffset $iat_rva $idata_va $idata_raw).ToString('X')))"
    
    # Print ILT entries
    $ilt_off = RvaToOffset $ilt_rva $idata_va $idata_raw
    $entry_idx = 0
    while ($true) {
        $entry_val = [BitConverter]::ToUInt64($b, $ilt_off + $entry_idx * 8)
        if ($entry_val -eq 0) {
            Write-Host "      ILT[$entry_idx]: NULL (Terminator)"
            break
        }
        
        # Check if imported by ordinal or name
        if (($entry_val -band 0x8000000000000000) -ne 0) {
            $ordinal = $entry_val -band 0xFFFF
            Write-Host "      ILT[$entry_idx]: Ordinal=$ordinal"
        } else {
            $hn_rva = $entry_val -band 0xFFFFFFFF
            $hn_off = RvaToOffset $hn_rva $idata_va $idata_raw
            $hint = [BitConverter]::ToUInt16($b, $hn_off)
            $func_name = ""
            $k = 2
            while ($b[$hn_off + $k] -ne 0) {
                $func_name += [char]$b[$hn_off + $k]
                $k++
            }
            Write-Host "      ILT[$entry_idx]: RVA=0x$($hn_rva.ToString('X')) Hint=$hint Name='$func_name'"
        }
        $entry_idx++
    }
    
    $idx++
}
