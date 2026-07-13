$b = [IO.File]::ReadAllBytes("C:/Users/Alumnos/.gemini/antigravity-cli/brain/b2303876-58bb-410e-80a1-189f37ab61d5/scratch/dump_pe.exe")
$pe = [BitConverter]::ToUInt32($b, 0x3C)
$opt = $pe + 4 + 20

Write-Host "Directory Entries for dump_pe.exe:"
for ($i = 0; $i -lt 16; $i++) {
    $rva = [BitConverter]::ToUInt32($b, $opt + 112 + $i * 8)
    $sz = [BitConverter]::ToUInt32($b, $opt + 112 + $i * 8 + 4)
    if ($rva -ne 0 -or $sz -ne 0) {
        Write-Host "  Directory [$i]: RVA=0x$($rva.ToString('X')) Size=0x$($sz.ToString('X'))"
    }
}
