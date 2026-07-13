$b_host = [IO.File]::ReadAllBytes("smoke_host.exe")
$pe_host = [BitConverter]::ToUInt32($b_host, 0x3C)
$sec_off_host = $pe_host + 4 + 20 + [BitConverter]::ToUInt16($b_host, $pe_host + 4 + 16)
$num_secs_host = [BitConverter]::ToUInt16($b_host, $pe_host + 4 + 2)

$b_out = [IO.File]::ReadAllBytes("smoke_out.exe")
$pe_out = [BitConverter]::ToUInt32($b_out, 0x3C)
$sec_off_out = $pe_out + 4 + 20 + [BitConverter]::ToUInt16($b_out, $pe_out + 4 + 16)
$num_secs_out = [BitConverter]::ToUInt16($b_out, $pe_out + 4 + 2)

function PrintSecs($b, $sec_off, $num_secs, $label) {
    Write-Host "`nSections for $label`:"
    for ($i = 0; $i -lt $num_secs; $i++) {
        $s = $sec_off + $i * 40
        $name = [System.Text.Encoding]::ASCII.GetString($b[$s..($s+7)]).TrimEnd([char]0)
        $vsize = [BitConverter]::ToUInt32($b, $s + 8)
        $vaddr = [BitConverter]::ToUInt32($b, $s + 12)
        $raw_sz = [BitConverter]::ToUInt32($b, $s + 16)
        $raw_ptr = [BitConverter]::ToUInt32($b, $s + 20)
        $chars = [BitConverter]::ToUInt32($b, $s + 36)
        
        Write-Host ("  [{0}] Name='{1}' VSz=0x{2:X} VA=0x{3:X} RawSz=0x{4:X} RawPtr=0x{5:X} Chars=0x{6:X8}" -f $i, $name, $vsize, $vaddr, $raw_sz, $raw_ptr, $chars)
    }
}

PrintSecs $b_host $sec_off_host $num_secs_host "Host"
PrintSecs $b_out $sec_off_out $num_secs_out "Out"
