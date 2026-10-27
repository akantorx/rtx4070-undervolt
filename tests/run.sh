#!/usr/bin/env bash
# Prueba uv4070.ps1 contra el NVML simulado de mock_nvml.c.
# Uso: tests/run.sh   (necesita gcc y PowerShell 7; PWSH=/ruta/a/pwsh si no está en el PATH)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
pwsh=${PWSH:-pwsh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/full" "$work/legacy"
gcc -shared -fPIC -Wall -Werror -o "$work/full/nvml.dll" "$root/tests/mock_nvml.c"
gcc -shared -fPIC -Wall -Werror -DLEGACY_ONLY -o "$work/legacy/nvml.dll" "$root/tests/mock_nvml.c"

export MOCK_NVML_STATE="$work/state" MOCK_NVML_LOG="$work/log"
failures=0

# run <variante> <args...>: estado limpio salvo que STATE esté definido; deja la salida en $out y el código en $rc.
run() {
    local lib=$1; shift
    rm -f "$MOCK_NVML_LOG"
    if [[ -n ${STATE:-} ]]; then echo "$STATE" > "$MOCK_NVML_STATE"; else rm -f "$MOCK_NVML_STATE"; fi
    rc=0
    out=$(LD_LIBRARY_PATH="$work/$lib" "$pwsh" -NoProfile -NonInteractive -File "$root/uv4070.ps1" "$@" 2>&1) || rc=$?
    calls=$(paste -sd '|' "$MOCK_NVML_LOG" 2>/dev/null || true)
}

check() {  # check <nombre> <condición...>
    local name=$1; shift
    if "$@"; then echo "ok    $name"; else
        echo "FALLO $name"; echo "  rc=$rc calls=[$calls] state=[$(cat "$MOCK_NVML_STATE" 2>/dev/null)]"
        echo "$out" | sed 's/^/  | /'; failures=$((failures + 1))
    fi
}

run full status
check 'status muestra la GPU y el offset' \
    eval '[[ $rc == 0 && $out == *"RTX 4070 (driver 566.36)"* && $out == *"Offset:       0 MHz"* && -z $calls ]]'

run full apply
check 'apply: tope antes que offset, preset balanced' \
    eval '[[ $rc == 0 && $calls == "lock 0 2610|offset 120" && $(cat $MOCK_NVML_STATE) == "120 0 2610 200000" ]]'

STATE='150 0 2610 200000' run full apply -Preset performance -OffsetMHz 90
check 'apply: si el offset baja, se baja antes de subir el tope' \
    eval '[[ $rc == 0 && $calls == "offset 90|lock 0 2745" ]]'

run full apply -MaxMHz 2700 -OffsetMHz 150 -PowerPct 80
check 'apply: límite de potencia en % del de fábrica' \
    eval '[[ $rc == 0 && $calls == "lock 0 2700|offset 150|power 160000" && $out == *"160 W"* ]]'

run full apply -PowerPct 50
check 'apply: potencia recortada al mínimo que admite la tarjeta' \
    eval '[[ $rc == 0 && $calls == *"power 120000" ]]'

MOCK_NVML_FAIL=lock0 run full apply
check 'apply: si el driver no acepta mínimo 0, usa 210 MHz' \
    eval '[[ $rc == 0 && $calls == "lock 0 2610|lock 210 2610|offset 120" ]]'

MOCK_NVML_FAIL=lock run full apply
check 'apply: sin tope no se toca el offset' \
    eval '[[ $rc == 1 && $calls != *"offset 120"* && $(cut -d" " -f1 $MOCK_NVML_STATE 2>/dev/null || echo 0) == 0 ]]'

MOCK_NVML_FAIL=power run full apply -PowerPct 90
check 'apply: si falla un paso vuelve a fábrica' \
    eval '[[ $rc == 1 && $calls == "lock 0 2610|offset 120|power 180000|offset 0|unlock" && $(cat $MOCK_NVML_STATE) == "0 0 0 200000" ]]'

MOCK_NVML_FAIL=offsetsnap run full apply
check 'apply: detecta un offset que el driver no respeta' \
    eval '[[ $rc == 1 && $out == *"informa de 115 MHz"* && $calls == *"|unlock" ]]'

run legacy apply
check 'apply: driver sin API moderna usa nvmlDeviceSetGpcClkVfOffset' \
    eval '[[ $rc == 0 && $calls == "lock 0 2610|legacy-offset 120" ]]'

STATE='120 0 2610 170000' run full reset
check 'reset: offset a 0, luego quitar tope, luego potencia' \
    eval '[[ $rc == 0 && $calls == "offset 0|unlock|power 200000" && $(cat $MOCK_NVML_STATE) == "0 0 0 200000" ]]'

STATE='120 0 2610 200000' MOCK_NVML_FAIL=offset run full reset
check 'reset: si el offset no baja, el tope se queda' \
    eval '[[ $rc == 1 && $calls != *unlock* && $(cat $MOCK_NVML_STATE) == "120 0 2610 200000" ]]'

MOCK_NVML_NAMES='NVIDIA GeForce RTX 4070 SUPER' run full apply
check 'otra GPU (4070 SUPER): se niega sin escribir nada' \
    eval '[[ $rc == 1 && -z $calls && $out == *"solo para la NVIDIA GeForce RTX 4070"* ]]'

MOCK_NVML_NAMES='NVIDIA GeForce RTX 3060;NVIDIA GeForce RTX 4070' run full apply
check 'varias GPUs: elige la 4070' \
    eval '[[ $rc == 0 && $calls == "lock 0 2610|offset 120" ]]'

run full apply -MaxMHz 3000
check 'tope fuera de rango: rechazado' eval '[[ $rc != 0 && -z $calls ]]'

run full apply -OffsetMHz 400
check 'offset fuera de rango: rechazado' eval '[[ $rc != 0 && -z $calls ]]'

run full monitor -Samples 2
check 'monitor: dos lecturas' \
    eval '[[ $rc == 0 && $(grep -c " MHz " <<< "$out") == 2 && $out == *potencia* ]]'

rc=0 calls=
out=$(LD_LIBRARY_PATH="$work/none" "$pwsh" -NoProfile -NonInteractive -File "$root/uv4070.ps1" status 2>&1) || rc=$?
check 'sin nvml.dll: mensaje claro' eval '[[ $rc == 1 && $out == *"no se puede cargar nvml.dll"*"reinstala) el driver"* ]]'

# Windows PowerShell 5.1 lee los .ps1 sin BOM como ANSI: el BOM es obligatorio.
check 'uv4070.ps1 empieza con BOM UTF-8' eval '[[ $(head -c3 "$root/uv4070.ps1" | od -An -tx1 | tr -d " ") == efbbbf ]]'
# Y si alguien lo guarda sin BOM, que no aparezcan bytes que en ANSI son comillas (p. ej. la "Ó" o la raya "—").
check 'uv4070.ps1 sin caracteres que rompan en ANSI' eval '! LC_ALL=C grep -qP "[\x84\x91-\x94]" "$root/uv4070.ps1"'

echo
if (( failures )); then echo "$failures prueba(s) fallida(s)"; exit 1; fi
echo 'Todas las pruebas pasan.'
