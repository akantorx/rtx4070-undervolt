# uv4070

Undervolt automático para **una NVIDIA GeForce RTX 4070** en Windows, en un solo script de PowerShell.
Sin MSI Afterburner, sin programa en segundo plano, sin perfiles.

Ejecutas `tune` una vez (unos 25 minutos) y te deja **una configuración para todo**: la que menos
consume perdiendo como mucho un 3 % de reloj respecto a serie. Antes de guardarla, la valida con su
propio test de estrés.

## Uso

Descarga `uv4070.ps1` y `uv4070.cmd` en la misma carpeta, abre **Terminal (Administrador)** en esa
carpeta y ejecuta:

```powershell
.\uv4070.cmd tune
```

Cierra antes los juegos, el navegador y todo lo que use la GPU. Al terminar, `tune` muestra una tabla
que compara la tarjeta de serie con la configuración nueva: reloj máximo, rendimiento, 1 % low, consumo,
temperatura y eficiencia. Después pregunta si quieres aplicarla siempre al iniciar Windows. Con eso ya
está. El informe queda guardado en `C:\Program Files\uv4070\tune-report.txt`.

## Qué hace `tune`

El undervolt se consigue con dos ajustes que el driver aplica a través de NVML (`nvml.dll`, la librería
oficial de NVIDIA): un **tope de reloj** y un **offset** que sube toda la curva tensión/frecuencia. Con la
curva subida, la GPU llega al tope con menos tensión que de serie y ya no sube más. Es el mismo método
que "subir la curva y aplanarla" en Afterburner.

1. **Mide la tarjeta de serie**: rendimiento, consumo y 1 % low con carga máxima, y el reloj máximo con
   una carga ligera, como la de un juego que no llega al límite de potencia.
2. **Fija el tope** un 3 % por debajo de ese reloj máximo y **sube el offset**, es decir, baja la
   tensión, de 30 en 30 MHz. Cada paso pasa el test de estrés completo. Al primer fallo afina en pasos de 15 y deja
   **30 MHz de margen** bajo el último valor estable. Si en algún momento más offset ya no reduce el
   consumo (la tensión ya está en el mínimo de la curva), se detiene sin arriesgar más.
3. **Confirma** el resultado con unos 10 minutos más de estrés. Si falla, baja 15 MHz y vuelve a confirmar.

¿Por qué así? La parte alta de la curva es donde la 4070 gasta más tensión para muy poco reloj. Renunciar
a ese 3 % y quitarle a la vez la tensión que tu chip no necesita es lo que más reduce el consumo. Además,
el reloj deja de rebotar contra el límite de potencia, y eso mejora los 1 % low.

Si prefieres ahorrar más a cambio de algo más de rendimiento: `.\uv4070.cmd tune -MaxLossPct 6`
(de 0 a 15).

Si el PC llega a colgarse durante la búsqueda, reinícialo y vuelve a ejecutar `tune`: sigue donde lo
dejó y cuenta ese paso como inestable.

## El test de estrés

Va incluido en el script y no necesita nada aparte. Es un compute shader de DirectX 11 que pone a
trabajar todas las unidades FP32 de la GPU:

- Cada hilo calcula 8 cadenas caóticas (`x = x·x + c`, una FMA por paso) y resume el recorrido en un hash.
  Como son caóticas, un error de cálculo de la GPU cambia el resultado final, y se compara con una
  referencia calculada a 1500 MHz y sin offset, donde cualquier 4070 es estable. Así detecta la
  inestabilidad **antes** de que el driver llegue a colgarse.
- No solo prueba el tope: también 300, 600 y 900 MHz por debajo, porque el offset desplaza toda la curva
  y cada reloj usa su propio punto de tensión. Y añade pulsos de carga y reposo, que es donde muchos
  undervolts fallan, en los cambios bruscos de tensión.
- Cuenta como fallo cualquier reinicio del driver (TDR), tanto si lo nota DirectX como si aparece en el
  registro de eventos de Windows.

Para probar tu configuración cuando quieras, por ejemplo tras actualizar el driver:

```powershell
.\uv4070.cmd stress              # 10 minutos
.\uv4070.cmd stress -Minutes 60
```

## Otros comandos

| Comando | Qué hace |
|---|---|
| `status` | Estado actual, configuración guardada y si se aplica al iniciar (también con doble clic en `uv4070.cmd`). |
| `monitor` | Reloj, consumo, temperatura y qué limita a la GPU, cada segundo. |
| `apply` | Aplica la configuración guardada. Con `-MaxMHz` y `-OffsetMHz`, una manual. Con `-PowerPct`, además un límite de potencia. |
| `install` | Aplica la configuración en cada inicio de sesión y al volver de suspensión, con una tarea programada. |
| `uninstall` | Quita la tarea y vuelve a valores de fábrica (la configuración guardada se conserva). |
| `reset` | Vuelve a valores de fábrica hasta el próximo `apply` o reinicio. |

Todo se guarda en `C:\Program Files\uv4070`: la copia del script que usa la tarea, `config.json`, el
informe y el registro. Solo un administrador puede modificar esa carpeta.

## Requisitos

- Windows 10 u 11 de 64 bits, con el PowerShell que trae Windows (5.1) o PowerShell 7.
- RTX 4070 de sobremesa. El script se niega a funcionar con cualquier otra GPU, incluidas la 4070 Super,
  la Ti y la de portátil.
- Driver de NVIDIA reciente (R555 o posterior recomendado).
- Terminal **como administrador** para todo salvo `status` y `monitor`.
- **No lo uses a la vez que** MSI Afterburner, NV-UV o NV-UV Play: tocan los mismos ajustes. Ponlos en
  valores por defecto y quítalos del arranque, o desinstálalos.

## Medidas de seguridad

- Un undervolt inestable no daña la tarjeta: como mucho cuelga el juego o reinicia el driver. Nunca se
  sube la tensión ni el límite de potencia.
- Nunca deja un offset positivo sin tope, porque eso sería un overclock: pone primero el tope y después
  el offset. `reset` lo hace en orden inverso, y si no consigue bajar el offset a 0, deja el tope puesto.
- Si falla cualquier paso, vuelve a valores de fábrica. Al cancelar `tune` con Ctrl+C, también.
- Comprueba que el driver aplica de verdad el offset pedido.
- Límites fijos: tope de 1500 a 3000 MHz, offset de 0 a +300 MHz y potencia del 50 al 100 %.

## Limitaciones

- **Lo he escrito sin acceso a una RTX 4070.** Lo verificado:
  - La lógica (orden de escrituras, búsqueda, margen, reanudación, rollback) contra un NVML y una 4070
    simulados (`tests/run.sh`).
  - El test de estrés DirectX 11 ejecutándose de verdad, con el compilador de shaders de Microsoft,
    bajo Wine y su D3D11 por software (`tests/stress-wine.sh`).
  - Que el código C# compila como C# 5, el que admite el PowerShell de Windows.

  Lo que solo se verá en tu PC: cómo responde el driver real, si la carga llega a P0 (`tune` lo
  comprueba y se niega si no) y las cifras de consumo y reloj. Si algo falla, el script vuelve a fábrica y
  muestra el error.
- El test de estrés carga los núcleos de cálculo, que es lo que limita un undervolt, pero no los de
  ray tracing ni los tensor. Tras `tune`, juega a algo exigente con RT. Si un juego se cierra o el driver
  se reinicia, baja el offset 15 MHz (`.\uv4070.cmd install -OffsetMHz <valor - 15>`).
- El rendimiento que mide es el de su propia carga. En juegos, la pérdida de reloj del 3 % suele notarse
  menos en FPS.
- NVML no permite leer la tensión ni el tope activo: para ver la tensión usa HWiNFO o GPU-Z.
- No incluye control de ventiladores, overclock de memoria ni perfiles por juego.

## Pruebas

En Linux, con `gcc` y PowerShell 7 (y `mcs` de Mono para la comprobación de C# 5):

```bash
tests/run.sh                       # PWSH=/ruta/a/pwsh si no está en el PATH
D3DCOMPILER=... tests/stress-wine.sh   # test de estrés bajo Wine; requisitos dentro del script
```

## Créditos

La forma de usar NVML para el offset (API moderna `nvmlDeviceSetClockOffsets` en P0, con
`nvmlDeviceSetGpcClkVfOffset` como alternativa) y el aviso de poner siempre el tope antes de subir la curva
vienen de [Green Curve](https://github.com/aufkrawall/green-curve) de aufkrawall (licencia MIT), el mismo
proyecto en el que se apoyan NV-UV y NV-UV Play. Este repositorio no contiene código de NV-UV, que es
software cerrado.
