$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_off_host = [BitConverter]::ToUInt32($b_host, 0x3C)
$opt_off_host = $pe_off_host + 4 + 20

$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_off_out = [BitConverter]::ToUInt32($b_out, 0x3C)
$opt_off_out = $pe_off_out + 4 + 20

function PrintVersions($b, $opt_off, $label) {
    $maj_os = [BitConverter]::ToUInt16($b, $opt_off + 40)
    $min_os = [BitConverter]::ToUInt16($b, $opt_off + 42)
    $maj_img = [BitConverter]::ToUInt16($b, $opt_off + 44)
    $min_img = [BitConverter]::ToUInt16($b, $opt_off + 46)
    $maj_sub = [BitConverter]::ToUInt16($b, $opt_off + 48)
    $min_sub = [BitConverter]::ToUInt16($b, $opt_off + 50)
    
    Write-Host "$label versions:"
    Write-Host "  OS Version: $maj_os.$min_os"
    Write-Host "  Image Version: $maj_img.$min_img"
    Write-Host "  Subsystem Version: $maj_sub.$min_sub"
}

PrintVersions $b_host $opt_off_host "Host"
PrintVersions $b_out $opt_off_out "Out"
