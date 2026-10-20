# Diagnóstico del NovaStar VX400 original

Para ejecutar en el PC Windows del sitio, entrando por RustDesk. Windows PowerShell 5.1 o PowerShell 7; no requiere Python, administrador ni paquetes adicionales. Se entregan juntos `Test-Vx400.ps1` y `Vx400.Protocol.psm1`.

## Doble clic en Windows

Extrae **todo el ZIP** a una carpeta local y abre `Diagnosticar-VX400.bat`. No lo ejecutes desde dentro del ZIP. Pedirá la IP; Enter sin IP recoge únicamente el inventario local/USB mediante la ventana abierta de NovaLCT. El BAT no habilita pruebas activas ni recibe comandos de escritura.

El lanzador utiliza la política `RemoteSigned` solamente en su proceso de PowerShell; no modifica la política permanente del equipo. Si Windows marca los archivos descargados como bloqueados, revisa su contenido y usa **Propiedades → Desbloquear** en los archivos del diagnóstico. Una política administrada puede seguir impidiendo su ejecución; conserva el mensaje para revisarlo.

## Primera ejecución desde PowerShell: solo lectura

1. Conecta el PC al **puerto Ethernet de control** del VX400 y pon ambos en la misma subred. Los RJ45 de salida a los paneles no son puertos LAN de control. Este script utiliza TCP, no USB; NovaLCT puede seguir usando USB para leer el hardware.
2. Entra por RustDesk y abre PowerShell en la carpeta del diagnóstico.
3. Sustituye la dirección de ejemplo por la IP real que aparece en el controlador:

```powershell
.\Test-Vx400.ps1 -DeviceAddress 192.168.0.10 -AssumeLatestFirmware
```

La IP es un ejemplo. El script no busca equipos por la red ni usa `ping`: las notas de ciertas versiones del VX400 indican que ICMP está deshabilitado.

Guarda `diagnostico.json` y `diagnostico.txt` en una subcarpeta única de `reports`. Los resultados se escriben durante la ejecución. No se envían a servicios externos.

Si solo está conectado por USB, primero recoge el inventario de NovaLCT:

```powershell
.\Test-Vx400.ps1 -InventoryOnly -CaptureNovaLctHardwareInfo -AssumeLatestFirmware
```

## Qué puede detectar y qué queda pendiente

| Comprobación | Evidencia |
|---|---|
| Identificación del controlador por TCP 5200 | Consulta ModelID documentada; respuesta y errores conservados |
| Entradas de vídeo | Consulta documentada de señal, resolución y frecuencia |
| Firmware mediante NovaLCT | Texto accesible de la ventana de información de hardware, cuando Windows lo expone |
| Software instalado | Versión local de NovaLCT/V-Can, separada del firmware |
| MRV412 | Modelo informado por el usuario; no se presenta como detectado sin evidencia |
| Firmware actualizado | `-AssumeLatestFirmware` registra una hipótesis, nunca inventa una versión |
| Deshumidificación al encender | Pendiente de comprobar en NovaLCT y mediante arranques físicos sin PC |

El protocolo público VX400 V1.0 consultado no define una consulta de versión de firmware del controlador. **ModelID no es firmware.** No se barren registros ni se trasplantan direcciones de VX1000, VX Pro o COEX.

Para recoger versiones desde NovaLCT:

1. Abre `Settings > Hardware Information` y pulsa `Refresh` para leer emisora y receptoras. No pulses `Set` para cambiar el reloj.
2. Deja esa ventana abierta y ejecuta:

```powershell
.\Test-Vx400.ps1 -DeviceAddress 192.168.0.10 -CaptureNovaLctHardwareInfo -AssumeLatestFirmware
```

La captura usa solo texto accesible de ventanas de hardware pertenecientes a NovaLCT; no hace clics ni captura el escritorio. Algunos controles de NovaLCT no publican ese texto. En ese caso queda `not_available`: entrega una captura o un archivo de texto con la información copiada desde la ventana:

```powershell
.\Test-Vx400.ps1 -InventoryOnly -HardwareInfoTextFile .\hardware.txt
```

Si ya leíste las versiones, puedes registrarlas con `-ObservedControllerFirmware` y `-ObservedReceiverFirmware`. Quedan etiquetadas como observaciones del usuario. Los textos detectados automáticamente conservan el contexto de emisora/receptora/MCU/FPGA y requieren comprobar su atribución; no se convierten en una versión única a partir de coincidencias ambiguas.

## Pruebas activas opcionales

Primero revisa el informe de lectura. Las pruebas activas se realizan con un gabinete seco y operativo, bajo supervisión y dentro de las indicaciones del fabricante. No son un tratamiento de humedad.

El script exige identificación válida del VX400 esperado, habilitación explícita y los valores originales de brillo y modo. No puede leer esos valores originales mediante el protocolo documentado, por lo que debes anotarlos antes en NovaLCT o en el panel del equipo.

Ejemplo **solo si el estado original realmente era brillo 30% y modo Normal**:

```powershell
.\Test-Vx400.ps1 -DeviceAddress 192.168.0.10 -EnableActiveTests `
  -TestBrightness 5 -RestoreBrightness 30 -RestoreMode Normal
```

Para probar un patrón blanco a brillo limitado:

```powershell
.\Test-Vx400.ps1 -DeviceAddress 192.168.0.10 -EnableActiveTests `
  -TestBrightness 5 -TestPattern White -HoldSeconds 2 `
  -RestoreBrightness 30 -RestoreMode Normal
```

El 5% es un valor de prueba funcional, **no una curva de deshumidificación ni una garantía térmica**. El script limita el brillo de prueba a 20% y el presupuesto de ejecución a 10 segundos, contado desde antes de la primera escritura e incluyendo la espera de ACK. La recuperación ocurre después y puede prolongar el estado aplicado; el límite no garantiza un tiempo máximo de exposición física. El modo previo debe ser Normal o Blackout; si estaba congelado o mostrando otro patrón, no uses estas pruebas sin preparar un estado conocido.

La restauración se intenta en `finally`, también si una escritura expira: un comando puede aplicarse aunque no llegue su respuesta. La restauración no está garantizada ante pérdida de red, energía, cierre forzado o fallo del dispositivo. Revisa el apartado `restoration` y verifica el resultado en la pantalla. Un ACK demuestra aceptación de protocolo; no prueba efecto óptico, protección ambiental ni humedad eliminada.

No se implementan reset, actualización de firmware, escritura de RCFG/mapeo/calibración, guardado de presets, cambio de entrada ni programación persistente.

## Cómo interpretar el informe

- `valid_reply`: respuesta correlacionada con la consulta y validada en estructura/checksum.
- `inconclusive`: timeout, error o respuesta inválida. No equivale a función no soportada.
- `evidence_collected`: evidencia observada que puede requerir atribución al dispositivo correcto.
- `acknowledged_not_optically_verified`: escritura aceptada; falta observar su efecto.
- `not_tested`: el script no realizó esa prueba.
- Código de salida 0: ejecución completada; no significa que todas las funciones estén soportadas. Código 2: comprobaciones sin resolver o restauración incompleta.

El documento de protocolo contiene erratas en algunos ejemplos. El diagnóstico conserva respuestas crudas y rechaza paquetes inválidos; no desactiva checksum para forzar un resultado positivo.

## Prueba de encendido autónomo

La función genérica `Settings > Cabinet Dehumidification` no demuestra soporte del VX400. El manual actual NovaLCT 5.9.2, sección 9.6, cita todas las receptoras y expresamente la emisora MCTRL4K; falta confirmar la combinación VX400 + MRV412.

Si el sistema permite configurar la función con una curva aprobada por el fabricante: guardar mediante esa función, cerrar NovaLCT, desconectar USB/control LAN manteniendo los datos LED y grabar **dos encendidos completos**. Verificar ausencia de destello previo, etapas correctas y regreso al contenido. Hace falta una persona local y un plan de recuperación del PC/red usados por RustDesk.

Después comprobar: corte solo de paneles mientras la emisora continúa el ciclo, corte solo de emisora, restauración de energía en distintos órdenes y corte a mitad del ciclo. El tiempo apagado de la emisora no representa necesariamente el de los paneles. Un gabinete solo valida su combinación de módulos, receptora y firmware.

## Fuentes y alcance de la verificación

- Protocolo VX400 V1.0, 2022-12-22, entregado por el usuario desde [NovaStar](https://wpan.novastar.tech/v2/sharing/818d1143ec32ffd5a545c19181): §§3.1.2, 3.2.1, 3.2.3, 3.3.2. Fuente primaria única; pendiente validación física.
- [VX400 manual V1.3.0](https://oss.novastar.tech/uploads/2025/06/VX400-All-in-One-Controller-User-Manual-V1.3.0.pdf): conexiones, información de versión y presets de capas.
- [VX400 notas V1.7.0](https://oss.novastar.tech/uploads/2024/12/VX400-V1.7.0-Release-Notes.txt): mínimos de software, ICMP y restricciones de rollback. No se afirma que sea el último firmware: la web china lista V1.7.1.
- [NovaLCT manual V5.9.2](https://en-website001.oss-us-east-1.aliyuncs.com/Specification/NovaLCT%20LED%20Configuration%20Tool%20for%20Synchronous%20Control%20System%20User%20Manual-V5.9.2.pdf): §9.5 información de hardware y §9.6 deshumidificación.

Consultado el 2026-10-20. Las pruebas de software con simulador se registran en `VALIDACION.md`. No hay resultado de un VX400 real ni verificación de la rama UI Automation en Windows hasta ejecutarlo en el sitio.
