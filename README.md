# Diagnóstico y monitor permanente del NovaStar VX400 original

## App nativa Windows — v0.5.0

Extrae el paquete completo y abre **`Abrir-Control-VX400.bat`**. Abre una ventana nativa de Windows, sin navegador ni servidor web. Requiere Windows PowerShell 5.1 y .NET Framework incluidos en Windows; no requiere Python ni paquetes adicionales para utilizarla. La conexión es Ethernet al puerto de control del VX400, TCP 5200.

La app permite:

- Ver comunicación, fase, progreso, tiempo restante y brillo solicitado. No se presenta el brillo como una medición óptica.
- Editar IP, horarios semanales, horas de secado, brillo y duración de cada fase y su contenido: blanco o vídeo de entrada.
- Crear y cancelar solicitudes de uso con el aviso necesario para completar el preuso; usa la zona de Bogotá por defecto.
- Guardar la configuración, ejecutar solo monitorización o activar el control, e instalar/retirar el inicio automático de Windows.
- Consultar los eventos y responder a una pérdida de comunicación desde la misma ventana.

### Control manual y prueba de secado

En **Control manual** puede ajustar brillo 0–100%, mostrar entrada de vídeo, negro o blanco de prueba. El valor inicial es 10%; cada mando verifica el ModelID y confirma Blackout → brillo → contenido. El resultado es una consigna con ACK, no una medición óptica. La salida elegida se mantiene después del mando. La versión 0.4.1 corrige un falso error al recoger el resultado de procesos en Windows PowerShell; los fallos reales muestran su código y conservan el detalle en **Registro**.

Fuera de una secuencia, aplicar un mando solicita una pausa al motor y desactiva temporalmente su inicio automático. El propio motor rechaza la pausa durante secado, preuso o enfriamiento: una vista atrasada de la GUI no permite cambiar el brillo en medio de la rampa. Use **Iniciar monitor** o **Iniciar control** para regresar al modo correspondiente; el control automático conserva sus verificaciones de instalación.

Para una prueba manual del secado: pulse **Detener**, espere y elija **Iniciar secado manual** en Control manual o Secuencias. Ejecuta una sola vez el perfil DRY completo (188 minutos inicialmente), sin crear reservas ni modificar horarios. Empieza desde el nivel inicial configurado; al completar confirma negro y reposo y termina. Cualquier lectura fallida, desconexión, pausa del proceso o fallo de ACK cancela la prueba y conserva una decisión pendiente; no arranca otra vez por recuperar red. Un nuevo clic explícito inicia de nuevo el perfil completo. **Detener** intenta Blackout/cero y termina la prueba.

Este modo es supervisado y explícito: no exige declarar alimentación conjunta ni arranque en negro del calendario automático, y tampoco marca esas casillas por su cuenta. Conserva la aceptación del perfil provisional. No comprime la curva para simular un tratamiento físico en pocos minutos ni certifica que haya eliminado humedad. La app no conmuta la corriente eléctrica de los paneles.

### Recuperar control de otra copia

Si aparece «Another watcher owns this endpoint» o acceso denegado al bloqueo, abra **Control manual → Recuperar control**. Windows solicitará permisos de administrador si hace falta. La app identifica nuestros motores para la misma IP y puerto, muestra PID/carpeta, pausa su inicio automático verificado e intenta una parada normal.

Si queda un proceso, revise la lista y pulse **Forzar cierre y recuperar**. Esta acción también interrumpe un secado activo. Solo cierra los procesos identificados y revisados; un propietario nuevo exige otra revisión. No elimina configuraciones, solicitudes, registros ni decisiones pendientes. Después elija **Mostrar negro** o **Iniciar secado manual**: la recuperación no reanuda el progreso. Al detener un controlador activo, su parada ordenada puede intentar negro y brillo cero.

Se detectan nuestras copias locales con scripts reconocidos. NovaLCT, otros programas y clientes de otros computadores quedan fuera de esta detección. No se retira la exclusión del endpoint ni se cierran todos los PowerShell. Detalles técnicos y aceptación en [recuperacion.md](docs/recuperacion.md).

### Perfil provisional recibido

El perfil inicial es la propuesta general compartida por el operador, cuyo origen se describió como una síntesis con IA. No se presenta como curva certificada del fabricante del panel. Los controles físicos de alimentación conjunta y arranque en negro deben comprobarse antes de habilitar escrituras.

| Proceso | Fases | Duración |
|---|---|---|
| Secado | 10→50%, mantener 50%, bajar por 30→15→10% | 188 min |
| Preuso | 10→50%, mantener 50%, 50→80%, estabilizar 80% | 240 min |
| Bajada | 80→50% en 20 min, después 50→10% en 16 min | 36 min |
| Reposo | Salida negra, consigna de brillo 10% | Resto del tiempo |

Se conservan los tiempos de la tabla: los secados iniciados a las 04:00 y 18:00 terminan a las **07:08 y 21:08**, respectivamente. El proceso no cabe en franjas de 150 minutos. La bajada del secado conserva el punto del 15% de la tabla. El enfriamiento aplica los 20 + 16 minutos de la actualización recibida; prevalecen esas duraciones sobre los intervalos anteriores que siguen entre paréntesis en la tabla. Las rampas se interpolan en incrementos pequeños, limitados a los 256 niveles del protocolo; no se resume un tratamiento interrumpido a partir del reloj.

El horario de uso indica cuándo debe estar disponible la imagen. El preuso empieza con la anticipación que requiera el perfil (cuatro horas inicialmente). Si el programa empieza tarde, completa la preparación antes de mostrar operación; no acorta fases para alcanzar la hora prevista. El fin de uso ejecuta la bajada y después reposo. Los horarios que cruzan medianoche están permitidos. Sin horario/solicitud activa ni secado programado, la pantalla queda en negro. Los horarios de uso se entregan vacíos para que el operador indique los del sitio.

El blanco está seleccionado para secado y las primeras fases de preuso; la rampa hacia operación y la estabilización utilizan el vídeo de entrada. Se puede cambiar por fase. Negro con consigna 10% no equivale a píxeles emitiendo al 10% ni demuestra mantenimiento térmico.

### Reconexión con decisión del operador

Una pérdida de comunicación interrumpe el avance. Cuando el VX400 vuelve a responder, la app muestra **«¿Iniciar preparación o dejar en reposo?»**. «Iniciar preparación» comienza el preuso completo desde el principio. «Dejar en reposo» conserva la pausa y permite decidir después. Si la ventana está cerrada, el controlador espera y muestra la decisión pendiente cuando se abra. Cerrar/reabrir la app, reiniciar el PC o cambiar a la instalación permanente no aprueba la decisión automáticamente.

El evento significa pérdida/recuperación del protocolo, no confirmación de un corte eléctrico. El protocolo revisado no documenta historial de encendidos/apagados ni uptime; la app registra lo que observa el PC. Si los paneles se apagan dejando el VX400 encendido, este método no los detecta. Tampoco detecta necesariamente cortes más cortos que el sondeo. El horario controla imagen y brillo; no conecta ni corta alimentación AC.

### Uso permanente y actualización

Primero configura y guarda desde la ventana. «Iniciar monitor» solo consulta; «Iniciar control» habilita los comandos del plan y exige las comprobaciones de arranque indicadas. Para trabajar con una instalación del sistema o gestionar su inicio automático, Windows puede solicitar permisos de administrador.

«Instalar al iniciar Windows» registra `NovaStar-VX400-Control` bajo SYSTEM. El motor sigue trabajando cuando se cierra la ventana y vuelve a arrancar con Windows. Configuración y código quedan en `%ProgramFiles%\NovaStar-VX400-Control`; datos, solicitudes y decisiones pendientes en `%ProgramData%\NovaStar-VX400-Control`. La app pasa a utilizar esas rutas después de instalar. La instalación inicial migra datos de una copia portátil detenida; una actualización no mezcla dos carpetas de datos distintas ni descarta decisiones pendientes.

Para cambiar la configuración de un motor en marcha, pulsa «Detener», espera y guarda. La detención de una tarea instalada desactiva primero sus disparadores para evitar que el watchdog la vuelva a iniciar. Iniciar de nuevo actualiza/reactiva la tarea en el modo seleccionado. Retirar el inicio automático conserva los datos; puede restaurarse una instalación propia identificada sin borrarlos.

Si antes se instaló el monitor v0.2.0 (`NovaStar-VX400-Watcher`), retira su tarea con `Quitar-Monitor-VX400.bat` antes de usar el nuevo controlador. El bloqueo por endpoint impide dos controladores simultáneos; no se desactiva una tarea desconocida por tener un nombre parecido.

La app no cambia la suspensión, red, firewall, drivers ni firmware. Configura el PC para permanecer operativo y comprueba su recuperación tras cortes de energía. Los comandos de oscurecimiento son best effort: perder el PC/red puede impedirlos. La protección del primer fotograma y la aceptación térmica siguen requiriendo comprobación física.

Pruebas y límites: [VALIDACION.md](VALIDACION.md). El diagnóstico y el monitor anteriores siguen incluidos abajo.

## Monitor automático por Ethernet — v0.2.0

El paquete incluye diagnóstico puntual y un monitor para dejar en el PC del sitio. **Por defecto solo consulta y registra; no cambia el brillo.** El motor de etapas está implementado, pero la curva de producción no viene configurada: depende de los paneles y su puesta en marcha.

1. Extrae todo el ZIP. Edita `watcher.config.json` con Bloc de notas para poner la IP del **puerto CONTROL Ethernet**, normalmente TCP 5200. Si están conectados LAN y USB, verifica `Communication > Mode > LAN Preferred` en el VX400. Conecta el PC a la misma subred. El monitor usa Ethernet; no implementa control USB.
2. Abre `Monitor-VX400.bat`. Consulta ModelID cada 2 segundos, con timeout de 1,5 segundos por intercambio. Los intervalos efectivos incluyen el tiempo de respuesta; no es una medición eléctrica instantánea.
3. Revisa `watcher-data/estado.json` y `watcher-data/eventos.jsonl`. Registra la primera conexión, los sondeos fallidos, tres fallos consecutivos como `sin_comunicacion` y dos respuestas correctas como conexión recuperada. Ctrl+C termina la ejecución manual.
4. Para dejarlo instalado, cierra el monitor manual y pulsa botón derecho → **Ejecutar como administrador** en `Instalar-Monitor-VX400.bat`. Instala una tarea de Windows bajo SYSTEM, sin inicio de sesión; arranca dentro de cinco minutos o al reiniciar. Un disparador cada cinco minutos relanza el proceso si terminó; no crea procesos paralelos.

La instalación copia código/configuración a `%ProgramFiles%\NovaStar-VX400-Watcher`; guarda estado y diario en `%ProgramData%\NovaStar-VX400-Watcher`. Ambos quedan protegidos para SYSTEM y Administradores. Para consultar esos archivos o cambiar la configuración instalada, usa una sesión elevada. Editar la copia del ZIP **no** cambia la copia instalada. El instalador rechaza instalaciones existentes; no realiza actualizaciones implícitas. El diario rota a aproximadamente 1 MB y conserva cinco archivos anteriores.

No deshabilita la suspensión de Windows: configura el PC del sitio para que permanezca operativo, tenga alimentación estable y Ethernet disponible. Prueba también su recuperación tras un corte de corriente; el arranque automático del propio PC depende del equipo/BIOS. La instalación no cambia firewall, red, drivers ni firmware.

### Habilitar una curva después de verificarla

`sequence.stages` acepta una lista en orden de objetos con `brightnessPercent` y `durationSeconds`. Los brillos deben ser crecientes o iguales; las duraciones son mínimas y pueden prolongarse por sondeo/ACK. No se acortan etapas para recuperar tiempo perdido. `normalBrightnessPercent` determina el brillo del contenido al finalizar. `pattern` puede ser `White` o `FromInput`; este último depende del contenido de vídeo que reciba el VX400.

El motor anterior también admite `sequence.ramp`: duración configurable, brillo inicial y pequeños intervalos hasta `normalBrightnessPercent`. Su plantilla de 70 minutos tiene los niveles pendientes y no reproduce el algoritmo interno de ViewSonic. Desactiva `ramp.enabled` para utilizar una lista explícita de etapas. La app nueva utiliza `plan.config.json` y sus fases; no mezcla ambos formatos.

No hay valores térmicos de ejemplo en la configuración distribuida. Los perfiles cortos del simulador son exclusivamente pruebas de software y no deben copiarse a una pantalla. Los porcentajes se convierten al valor entero 0–255 redondeando hacia abajo; no son una medida de temperatura ni de humedad.

Antes de habilitar el ciclo hay que documentar `curveReference` y verificar los campos `approved`, `panelPowerCouplingVerified` y `startupProtectionVerified`. Esas declaraciones del operador no son sensores ni certifican por sí mismas el montaje. Validación sin red:

```powershell
.\Watch-Vx400.ps1 -ConfigPath .\mi-perfil.site.json -EnableSequence -ValidateOnly
```

Con el perfil validado y la instalación probada, la ejecución supervisada es:

```powershell
.\Watch-Vx400.ps1 -ConfigPath .\mi-perfil.site.json -EnableSequence
```

La instalación con secuencia se hace desde **Windows PowerShell 5.1 como administrador**, usando `Install-Vx400Watcher.ps1 -ConfigPath .\mi-perfil.site.json -EnableSequence`. El BAT de instalación siempre instala el modo de solo lectura. Usa `-StartNow` si quieres que la tarea arranque inmediatamente; sin ese parámetro también arrancará automáticamente dentro de cinco minutos o al reiniciar.

En modo secuencia: conexión inicial/recuperación estable → Blackout → primer brillo → patrón elegido → etapas → Blackout → brillo normal → Normal. Cada paso requiere respuesta válida. Una pérdida de comunicación descarta el avance y exige un nuevo ciclo desde el principio. Un fallo de comando de la secuencia deja `fallo` retenido, intenta Blackout/cero y requiere inspección y reinicio del proceso. Los intentos de oscurecer un equipo sin comunicación son best effort; al volver se requieren nuevos ACK antes de mostrar el patrón. El cierre normal intenta Blackout/cero; matar el proceso o cortar la alimentación puede impedirlo.

**Límites del disparador:** perder comunicación puede ser un corte de red. Si se apagan solo los paneles y el VX400 sigue respondiendo, el monitor no lo detecta. Un corte breve entre sondeos también puede pasar inadvertido. No hay detección de humedad. La red y el PC no garantizan oscuridad desde el primer instante de encendido: ese intervalo requiere comportamiento de arranque comprobado o protección física. Debe comprobarse la alimentación conjunta de paneles y controlador antes de utilizar este disparador para el ciclo.

Para retirar la tarea, ejecuta `Quitar-Monitor-VX400.bat` como administrador. Conserva código y registros; revisa el estado físico de la pantalla porque una terminación forzada no garantiza ejecutar los comandos de cierre. El diagnóstico puntual sigue disponible abajo.

Diseño y aceptación en sitio: [docs/secuenciador.md](docs/secuenciador.md). [Validación](VALIDACION.md). No se afirma compatibilidad nativa de deshumidificación, eficacia térmica ni autonomía sin PC.

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
