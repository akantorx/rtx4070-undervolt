# uv4070

Undervolt para **una NVIDIA GeForce RTX 4070** en Windows, en un solo script de PowerShell.
Sin MSI Afterburner, sin programa en segundo plano, sin base de datos de juegos.

Es lo mismo que hacen NV-UV o Afterburner con su "Voltage Lock" o curva aplanada, pero reducido a lo
único que hace falta para una sola tarjeta:

1. **Tope de reloj** (`-MaxMHz`): la GPU nunca pasa de esa frecuencia.
2. **Offset de curva** (`-OffsetMHz`): toda la curva tensión/frecuencia sube esos MHz.

Con la curva subida, la GPU llega al tope con menos tensión que de serie y ahí se queda. Es justo el
método clásico de Afterburner: subir la curva y aplanarla a partir de un punto. Se hace con
**NVML** (`nvml.dll`), la librería oficial que instala el driver de NVIDIA.

## Requisitos

- Windows 10 u 11 de 64 bits.
- RTX 4070 de sobremesa. El script se niega a funcionar con cualquier otra GPU, incluidas la 4070 Super, la Ti y la de portátil.
- Driver de NVIDIA reciente (R555 o posterior recomendado).
- PowerShell **como administrador** para `apply`, `reset`, `install` y `uninstall`.
- **No lo uses a la vez que** MSI Afterburner, NV-UV o NV-UV Play: todos tocan los mismos ajustes.
  Ponlos en valores por defecto y quítalos del arranque, o desinstálalos.

## Uso

Descarga `uv4070.ps1` y `uv4070.cmd` en la misma carpeta, abre **Terminal (Administrador)** en esa
carpeta y ejecuta:

```powershell
.\uv4070.cmd                 # estado (también con doble clic)
.\uv4070.cmd apply           # preset balanced: tope 2610 MHz, offset +120 MHz
.\uv4070.cmd monitor         # reloj, consumo, temperatura cada segundo
.\uv4070.cmd reset           # valores de fábrica
```

El `.cmd` solo evita tener que cambiar la ExecutionPolicy. También vale
`powershell -ExecutionPolicy Bypass -File .\uv4070.ps1 apply`.

| Preset        | Tope     |
|---------------|----------|
| `eco`         | 2400 MHz |
| `balanced`    | 2610 MHz |
| `performance` | 2745 MHz |

Como referencia, una 4070 de serie suele subir a unos 2700-2800 MHz en juegos. El preset solo elige
el tope. El offset depende de tu chip concreto y se ajusta aparte:

```powershell
.\uv4070.cmd apply -Preset eco
.\uv4070.cmd apply -MaxMHz 2700 -OffsetMHz 150
.\uv4070.cmd apply -PowerPct 85        # además, límite de potencia al 85 % del de fábrica
```

## Cómo afinarlo

1. `apply` con los valores por defecto (+120 MHz).
2. Juega a lo más exigente que tengas, o deja en bucle una prueba de estrés (3DMark Speed Way o Port Royal) durante
   20-30 minutos. En otra ventana, `monitor` te muestra que el reloj se queda en el tope y que el consumo baja.
   La tensión no la da NVML: para verla usa HWiNFO o GPU-Z.
3. Si es estable, sube el offset 15 MHz (`-OffsetMHz 135`, `150`...) y repite.
4. Si un juego se cierra, aparecen artefactos o el driver se reinicia, vuelve al último valor estable.
   Una inestabilidad por undervolt no daña la tarjeta: como mucho cuelga el juego o el driver.
5. Cuando lo tengas, déjalo fijo:

```powershell
.\uv4070.cmd install -MaxMHz 2610 -OffsetMHz 150
```

`install` aplica los ajustes ahora, copia el script a `C:\Program Files\uv4070` y crea una tarea
programada (`uv4070`) que los vuelve a aplicar en cada inicio de sesión y al volver de suspensión. Lo
que hizo la última vez queda en `C:\ProgramData\uv4070\uv4070.log`. Para quitarlo todo usa `.\uv4070.cmd uninstall`.

Los ajustes viven en el driver, no en la tarjeta: al reiniciar sin la tarea instalada, o al
reinstalar el driver, todo vuelve a fábrica.

## Medidas de seguridad

- Nunca deja un offset positivo sin tope, porque eso sería un overclock: primero pone el tope y después el offset.
  `reset` lo hace en orden inverso, y si no consigue bajar el offset a 0, deja el tope puesto.
- Si falla cualquier paso de `apply`, vuelve a valores de fábrica y muestra el error de NVML.
- Comprueba que el driver ha aplicado el offset pedido.
- Límites fijos: tope de 1500 a 2850 MHz, offset de 0 a +300 MHz y potencia del 50 al 100 %. Nunca sube el límite de potencia.

## Limitaciones

- Lo he escrito sin acceso a una RTX 4070 real. La lógica (orden de escrituras, rollback, detección de la
  GPU, compatibilidad con drivers antiguos) está probada con un NVML simulado (`tests/`), pero no con el driver de
  verdad. La primera vez, usa `apply` a mano y compruébalo con `monitor` y HWiNFO antes de usar `install`.
- NVML no permite leer el tope activo: `status` muestra el offset, y el tope se ve en `monitor` con la GPU en carga.
- No incluye control de ventiladores, overclock de memoria, perfiles por juego, overlay ni escáner de estabilidad.

## Pruebas

En Linux, con `gcc` y PowerShell 7:

```bash
tests/run.sh            # PWSH=/ruta/a/pwsh si no está en el PATH
```

## Créditos

La forma de usar NVML para el offset (API moderna `nvmlDeviceSetClockOffsets` en P0, con
`nvmlDeviceSetGpcClkVfOffset` como alternativa) y el aviso de poner siempre el tope antes de subir la curva
vienen de [Green Curve](https://github.com/aufkrawall/green-curve) de aufkrawall (licencia MIT), el mismo
proyecto en el que se basan NV-UV y NV-UV Play. Este repositorio no contiene código de NV-UV, que es software cerrado.
