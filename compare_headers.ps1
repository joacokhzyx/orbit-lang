function Get-PEInfo($file) {
    $b = [IO.File]::ReadAllBytes($file)
    $pe_off = [BitConverter]::ToUInt32($b, 0x3C)
    $coff_chars = [BitConverter]::ToUInt16($b, $pe_off + 4 + 18)
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
    $num_secs = [BitConverter]::ToUInt16($b, $pe_off + 4 + 2)

    [PSCustomObject]@{
        File = $file
        CoffChars = "0x$($coff_chars.ToString('X'))"
        Magic = "0x$($magic.ToString('X'))"
        EntryPoint = "0x$($entry_point.ToString('X'))"
        BaseOfCode = "0x$($base_code.ToString('X'))"
        ImageBase = "0x$($image_base.ToString('X'))"
        SectionAlign = "0x$($sec_align.ToString('X'))"
        FileAlign = "0x$($file_align.ToString('X'))"
        SizeOfImage = "0x$($size_image.ToString('X'))"
        SizeOfHeaders = "0x$($size_headers.ToString('X'))"
        Subsystem = $subsystem
        DllCharacteristics = "0x$($dll_chars.ToString('X'))"
        NumRvaSizes = $num_rva_sizes
        NumSections = $num_secs
    }
}

$host_info = Get-PEInfo "smoke_host.exe"
$out_info = Get-PEInfo "smoke_out.exe"

$host_info
$out_info
