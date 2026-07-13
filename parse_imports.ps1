$b = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_off = [BitConverter]::ToUInt32($b, 0x3C)
$opt_sz = [BitConverter]::ToUInt16($b, $pe_off + 4 + 16)
$sec_off_hdr = $pe_off + 4 + 20 + $opt_sz
$num_secs = [BitConverter]::ToUInt16($b, $pe_off + 4 + 2)
$image_base = [BitConverter]::ToUInt64($b, $pe_off + 4 + 20 + 24)

# Read Import Table RVA and Size from Data Directory
$opt_off = $pe_off + 4 + 20
$import_off = $opt_off + 120
$idata_va = [BitConverter]::ToUInt32($b, $import_off)
$idata_sz = [BitConverter]::ToUInt32($b, $import_off + 4)

Write-Host "ImageBase: 0x$($image_base.ToString('X'))"
Write-Host "Import Table RVA: 0x$($idata_va.ToString('X')), Size: 0x$($idata_sz.ToString('X'))"

function RvaToFile($rva) {
    for ($i = 0; $i -lt $num_secs; $i++) {
        $s = $sec_off_hdr + $i * 40
        $sec_va = [BitConverter]::ToUInt32($b, $s + 12)
        $sec_vsz = [BitConverter]::ToUInt32($b, $s + 8)
        $sec_raw = [BitConverter]::ToUInt32($b, $s + 20)
        if ($rva -ge $sec_va -and $rva -lt ($sec_va + $sec_vsz) -and $sec_raw -ne 0) {
            return $sec_raw + ($rva - $sec_va)
        }
    }
    return -1
}

# Parse import descriptors
Write-Host "`nImport Descriptors:"
$desc_off = RvaToFile $idata_va
if ($desc_off -eq -1) {
    Write-Host "Could not resolve Import Table RVA to file offset."
    exit
}

$idx = 0
while ($true) {
    $off = $desc_off + $idx * 20
    $ilt_rva = [BitConverter]::ToUInt32($b, $off)
    $ts = [BitConverter]::ToUInt32($b, $off + 4)
    $fc = [BitConverter]::ToUInt32($b, $off + 8)
    $name_rva = [BitConverter]::ToUInt32($b, $off + 12)
    $iat_rva = [BitConverter]::ToUInt32($b, $off + 16)
    
    if ($ilt_rva -eq 0 -and $name_rva -eq 0 -and $iat_rva -eq 0) {
        Write-Host "  [end of import table]"
        break
    }
    
    $dll_name_off = RvaToFile $name_rva
    $dll_name = ""
    if ($dll_name_off -ge 0) {
        $p = $dll_name_off
        while ($b[$p] -ne 0) { $dll_name += [char]$b[$p]; $p++ }
    }
    Write-Host "  DLL: '$dll_name' ILT_RVA=0x$($ilt_rva.ToString('X')) IAT_RVA=0x$($iat_rva.ToString('X'))"
    
    # Parse ILT entries
    $ilt_off = RvaToFile $ilt_rva
    $fi = 0
    while ($true) {
        $entry_off = $ilt_off + $fi * 8
        $entry = [BitConverter]::ToUInt64($b, $entry_off)
        if ($entry -eq 0) { break }
        # Check if ordinal import (high bit set)
        if ($entry -band 0x8000000000000000) {
            $ord = $entry -band 0xFFFF
            Write-Host "    #$ord (ordinal)"
        } else {
            $hn_rva = [uint32]($entry -band 0x7FFFFFFF)
            $hn_off = RvaToFile $hn_rva
            if ($hn_off -ge 0) {
                $hint = [BitConverter]::ToUInt16($b, $hn_off)
                $fname = ""
                $p = $hn_off + 2
                while ($b[$p] -ne 0) { $fname += [char]$b[$p]; $p++ }
                Write-Host "    [$hint] $fname"
            }
        }
        $fi++
        if ($fi -gt 50) { Write-Host "    ... (truncated)"; break }
    }
    
    $idx++
    if ($idx -gt 20) { Write-Host "  Too many DLLs"; break }
}
