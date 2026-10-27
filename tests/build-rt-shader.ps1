# Compila el shader de ray tracing de uv4070.ps1 (HLSL, cs_6_5) con dxc y comprueba
# que el DXIL embebido en el script corresponde a ese HLSL. Con -Embed escribe en el
# script el DXIL recién compilado y el hash del HLSL.
#
# dxc viene con el Windows SDK (Windows Kits\10\bin\<versión>\x64\dxc.exe); si no está,
# se descarga el paquete NuGet Microsoft.Direct3D.DXC. -Dxc fuerza una ruta concreta.
# Lo lanza .github/workflows/tests.yml, que imprime el DXIL por si hay que embeberlo a mano.
param(
    [switch]$Embed,
    [string]$Dxc
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'uv4070.ps1'
$text = [IO.File]::ReadAllText($scriptPath)

$block = [regex]::Match($text, '(?s)// RT-HLSL-BEGIN\r?\n(.*?)\r?\n[ \t]*// RT-HLSL-END')
if (-not $block.Success) { throw 'No se encuentra el bloque RT-HLSL en uv4070.ps1.' }
# Del literal C# @"..." al HLSL: sin el prefijo, el sufijo ni las comillas dobladas.
$hlsl = ($block.Groups[1].Value -replace '(?s)^.*?@"', '' -replace '(?s)";\s*$', '') -replace '""', '"' -replace "`r", ''
$sha = [Security.Cryptography.SHA256]::Create()
$hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($hlsl))) -replace '-', '').ToLowerInvariant()
$embedded = [regex]::Match($text, 'const string ShaderHash = "([0-9a-f]*)"').Groups[1].Value

if (-not $Dxc) {
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $found = @(Get-ChildItem -Path (Join-Path $kits '*\x64\dxc.exe') -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    if ($found.Count) { $Dxc = $found[0].FullName }
}
if (-not $Dxc) {
    $nuget = Join-Path ([IO.Path]::GetTempPath()) 'uv4070-dxc'
    New-Item -ItemType Directory -Force -Path $nuget | Out-Null
    & nuget install Microsoft.Direct3D.DXC -OutputDirectory $nuget -ExcludeVersion | Out-Host
    $Dxc = Join-Path $nuget 'Microsoft.Direct3D.DXC\build\native\bin\x64\dxc.exe'
}
if (-not (Test-Path -LiteralPath $Dxc)) { throw "No se encuentra dxc.exe ($Dxc)." }

$work = Join-Path ([IO.Path]::GetTempPath()) ('uv4070-rt-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$source = Join-Path $work 'rt.hlsl'
$object = Join-Path $work 'rt.cso'
[IO.File]::WriteAllText($source, $hlsl, (New-Object Text.UTF8Encoding $false))
& $Dxc -T cs_6_5 -E main -O3 -Fo $object $source | Out-Host
if ($LASTEXITCODE -ne 0) { throw "dxc ha fallado ($LASTEXITCODE)." }
$dxil = [IO.File]::ReadAllBytes($object)
$base64 = [Convert]::ToBase64String($dxil)
$lines = @([regex]::Matches($base64, '.{1,76}') | ForEach-Object { $_.Value })

Write-Host ('dxc: {0}' -f $Dxc)
Write-Host ('HLSL: sha256 {0} ({1} bytes); DXIL: {2} bytes' -f $hash, $hlsl.Length, $dxil.Length)
Write-Host 'RT-DXIL-BEGIN'
$lines | ForEach-Object { Write-Host $_ }
Write-Host 'RT-DXIL-END'

if ($Embed) {
    $body = '        const string ShaderHash = "' + $hash + '";' + "`n" + '        const string Dxil =' + "`n" +
        (($lines | ForEach-Object { '            "' + $_ + '"' }) -join (' +' + "`n")) + ';'
    $new = [regex]::Replace($text, '(?s)(// RT-DXIL-BEGIN[^\r\n]*\r?\n).*?(\r?\n[ \t]*// RT-DXIL-END)', { param($m) $m.Groups[1].Value + $body + $m.Groups[2].Value })
    [IO.File]::WriteAllText($scriptPath, $new, (New-Object Text.UTF8Encoding $true))
    Write-Host "DXIL embebido en $scriptPath."
} elseif ($embedded -ne $hash) {
    throw "El HLSL de uv4070.ps1 (sha256 $hash) no coincide con el DXIL embebido ($embedded): ejecuta tests/build-rt-shader.ps1 -Embed."
} else {
    Write-Host 'El DXIL embebido corresponde al HLSL del script.'
}
