$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_off_host = [BitConverter]::ToUInt32($b_host, 0x3C)
$opt_off_host = $pe_off_host + 4 + 20

$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_off_out = [BitConverter]::ToUInt32($b_out, 0x3C)
$opt_off_out = $pe_off_out + 4 + 20

function PrintSizes($b, $opt_off, $label) {
    $code_sz = [BitConverter]::ToUInt32($b, $opt_off + 4)
    $init_sz = [BitConverter]::ToUInt32($b, $opt_off + 8)
    $uninit_sz = [BitConverter]::ToUInt32($b, $opt_off + 12)
    
    Write-Host "$label Optional Header sizes:"
    Write-Host "  SizeOfCode: 0x$($code_sz.ToString('X'))"
    Write-Host "  SizeOfInitData: 0x$($init_sz.ToString('X'))"
    Write-Host "  SizeOfUninitData: 0x$($uninit_sz.ToString('X'))"
}

PrintSizes $b_host $opt_off_host "Host"
PrintSizes $b_out $opt_off_out "Out"
