#!/usr/bin/env bash
# Ejecuta el test de estrés DirectX 11 de uv4070.ps1 bajo Wine, con su D3D11 por
# software, para comprobar la parte que no cubre run.sh sin una GPU real.
#
# Necesita: mono-mcs, mingw-w64, wine64 con wine-mono instalado en el prefijo, un
# servidor X (p. ej. Xvfb :99 y DISPLAY=:99) y el compilador de shaders de
# Microsoft: D3DCOMPILER=/ruta/a/d3dcompiler_47.dll (sirve D3DCompiler_47_cor3.dll
# del paquete NuGet Microsoft.WindowsDesktop.App.Runtime.win-x64).
# Uso: D3DCOMPILER=... tests/stress-wine.sh ["nombre del adaptador de Wine"]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
wine=${WINE:-wine64}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

awk "/Add-Type -TypeDefinition @'/{f=1;next} /^'@\$/{f=0} f" "$root/uv4070.ps1" > "$work/uv4070.cs"
mcs -langversion:5 -platform:x64 -warnaserror+ -out:"$work/harness.exe" "$work/uv4070.cs" "$root/tests/stress_harness.cs"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Werror -o "$work/nvml.dll" "$root/tests/mock_nvml.c"
cp "${D3DCOMPILER:?indica D3DCOMPILER=/ruta/a/d3dcompiler_47.dll}" "$work/d3dcompiler_47.dll"

cd "$work"
WINEDEBUG=-all WINEDLLOVERRIDES="d3dcompiler_47=n" MOCK_NVML_STATE='C:\windows\temp\uv4070-state' \
    MOCK_NVML_LOG='C:\windows\temp\uv4070-log' "$wine" harness.exe "${1:-NVIDIA GeForce GTX 470}" nvml
