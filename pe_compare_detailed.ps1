$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_host = [BitConverter]::ToUInt32($b_host, 0x3C)

$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_out = [BitConverter]::ToUInt32($b_out, 0x3C)

function Get-PEInfo($b, $pe) {
    $coff = $pe + 4
    $opt = $coff + 20
    
    $info = [ordered]@{
        "Machine" = "0x$(([BitConverter]::ToUInt16($b, $coff)).ToString('X4'))"
        "NumberOfSections" = [BitConverter]::ToUInt16($b, $coff + 2)
        "TimeDateStamp" = "0x$(([BitConverter]::ToUInt32($b, $coff + 4)).ToString('X8'))"
        "PointerToSymbolTable" = "0x$(([BitConverter]::ToUInt32($b, $coff + 8)).ToString('X8'))"
        "NumberOfSymbols" = [BitConverter]::ToUInt32($b, $coff + 12)
        "SizeOfOptionalHeader" = "0x$(([BitConverter]::ToUInt16($b, $coff + 16)).ToString('X4'))"
        "Characteristics" = "0x$(([BitConverter]::ToUInt16($b, $coff + 18)).ToString('X4'))"
        
        # Optional Header
        "Magic" = "0x$(([BitConverter]::ToUInt16($b, $opt)).ToString('X4'))"
        "MajorLinkerVersion" = $b[$opt + 2]
        "MinorLinkerVersion" = $b[$opt + 3]
        "SizeOfCode" = "0x$(([BitConverter]::ToUInt32($b, $opt + 4)).ToString('X8'))"
        "SizeOfInitializedData" = "0x$(([BitConverter]::ToUInt32($b, $opt + 8)).ToString('X8'))"
        "SizeOfUninitializedData" = "0x$(([BitConverter]::ToUInt32($b, $opt + 12)).ToString('X8'))"
        "AddressOfEntryPoint" = "0x$(([BitConverter]::ToUInt32($b, $opt + 16)).ToString('X8'))"
        "BaseOfCode" = "0x$(([BitConverter]::ToUInt32($b, $opt + 20)).ToString('X8'))"
        "ImageBase" = "0x$(([BitConverter]::ToUInt64($b, $opt + 24)).ToString('X16'))"
        "SectionAlignment" = "0x$(([BitConverter]::ToUInt32($b, $opt + 32)).ToString('X8'))"
        "FileAlignment" = "0x$(([BitConverter]::ToUInt32($b, $opt + 36)).ToString('X8'))"
        "MajorOSVersion" = [BitConverter]::ToUInt16($b, $opt + 40)
        "MinorOSVersion" = [BitConverter]::ToUInt16($b, $opt + 42)
        "MajorImageVersion" = [BitConverter]::ToUInt16($b, $opt + 44)
        "MinorImageVersion" = [BitConverter]::ToUInt16($b, $opt + 46)
        "MajorSubsystemVersion" = [BitConverter]::ToUInt16($b, $opt + 48)
        "MinorSubsystemVersion" = [BitConverter]::ToUInt16($b, $opt + 50)
        "Win32VersionValue" = "0x$(([BitConverter]::ToUInt32($b, $opt + 52)).ToString('X8'))"
        "SizeOfImage" = "0x$(([BitConverter]::ToUInt32($b, $opt + 56)).ToString('X8'))"
        "SizeOfHeaders" = "0x$(([BitConverter]::ToUInt32($b, $opt + 60)).ToString('X8'))"
        "CheckSum" = "0x$(([BitConverter]::ToUInt32($b, $opt + 64)).ToString('X8'))"
        "Subsystem" = [BitConverter]::ToUInt16($b, $opt + 68)
        "DllCharacteristics" = "0x$(([BitConverter]::ToUInt16($b, $opt + 70)).ToString('X4'))"
        "SizeOfStackReserve" = "0x$(([BitConverter]::ToUInt64($b, $opt + 72)).ToString('X16'))"
        "SizeOfStackCommit" = "0x$(([BitConverter]::ToUInt64($b, $opt + 80)).ToString('X16'))"
        "SizeOfHeapReserve" = "0x$(([BitConverter]::ToUInt64($b, $opt + 88)).ToString('X16'))"
        "SizeOfHeapCommit" = "0x$(([BitConverter]::ToUInt64($b, $opt + 96)).ToString('X16'))"
        "LoaderFlags" = "0x$(([BitConverter]::ToUInt32($b, $opt + 104)).ToString('X8'))"
        "NumberOfRvaAndSizes" = [BitConverter]::ToUInt32($b, $opt + 108)
    }
    return $info
}

$host_info = Get-PEInfo $b_host $pe_host
$out_info = Get-PEInfo $b_out $pe_out

Write-Host "Field-by-Field PE Optional Header Comparison:"
$host_info.Keys | ForEach-Object {
    $k = $_
    $h = $host_info[$k]
    $o = $out_info[$k]
    if ($h -eq $o) {
        Write-Host "  $k`: $h (Identical)"
    } else {
        Write-Host "  $k`: Host=$h | Out=$o (DIFFERENT)" -ForegroundColor Yellow
    }
}
