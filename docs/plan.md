# Plan diario VX400

El plan aplica la propuesta general compartida por el operador, de origen no certificado. No es una curva del fabricante ni una medición de humedad, temperatura o alimentación. Las duraciones y porcentajes reproducen esa propuesta; verificar el resultado físico en sitio sigue pendiente. El programa controla contenido y brillo por Ethernet: no conmuta alimentación AC.

## Requisitos verificables

- Cuando se ejecuta sin `-EnableControl`, solo consulta el ModelID original VX400 `0x6211` y publica el plan deseado. Ningún calendario habilita escrituras por sí solo.
- Cuando hay una solicitud o un horario de uso, debe completar todo el precalentamiento antes de OPERATING, aunque el proceso llegue tarde. No extiende uso más allá de la hora de fin.
- Si se cancela o termina el uso, baja desde el último nivel confirmado; nunca sube al 80% para iniciar el enfriamiento.
- Si falla una lectura o hay una pausa larga del proceso, descarta el progreso inmediatamente. Tras una conexión previa en modo control, conserva una pregunta al operador en disco y espera su respuesta en negro. Reiniciar el proceso no evita esa pregunta.
- Si se pierde un ACK de escritura, retiene FAULT hasta reiniciar el proceso. No vuelve automáticamente a Normal con brillo incierto.
- Si falla la configuración, el archivo de solicitudes o el almacenamiento, intenta Blackout y brillo cero y termina con error. Una terminación forzada puede impedir esos intentos.

## Configuración y curvas

`plan.config.json` requiere `schemaVersion: 1`, IPv4 canónica, puerto, tiempos de sondeo y los perfiles completos. No hay instalación de dependencias. Windows PowerShell 5.1; las pruebas de desarrollo también usan PowerShell 7 en Linux.

Por defecto: `192.168.0.10:5200`, consulta cada 2 segundos, timeout 1500 ms, tres fallos para declarar inaccesible y dos respuestas correctas para conexión estable. Un solo fallo descarta el progreso; el umbral de tres solo afecta el aviso. Las zonas `SA Pacific Standard Time` y `America/Bogota` se resuelven según el sistema.

| Perfil | Recorrido | Duración |
|---|---|---|
| DRY | 10→50 en 24 min; 50 durante 140 min; 50→30 en 12 min; 30→15 en 6 min; 15→10 en 6 min | 188 min |
| PREHEAT | 10→50 en 24 min; 50 durante 96 min; 50→80 en 60 min; 80 durante 60 min | 240 min |
| COOLDOWN | 80→50 en 20 min; 50→10 en 16 min, recortado al nivel confirmado si es menor | 36 min |

La actualización recibida fija COOLDOWN en 20 + 16 minutos. Prevalece esa columna de duración sobre los intervalos antiguos entre paréntesis; el motor interpola suavemente cada fase.

DRY empieza a las 04:00 y 18:00 de Bogotá; a tiempo y sin interrupciones termina a las 07:08 y 21:08. Una conexión tardía dentro del intervalo realiza la curva completa; no comprime las etapas para respetar una ventana inventada de 150 minutos. Cada etapa se interpola en cada sondeo y el byte de brillo se redondea hacia abajo; solo se escribe cuando cambia, salvo confirmaciones necesarias al cambiar de patrón. Los hitos de bajada DRY son 40, 30, 15 y 10 cada seis minutos.

El valor global `conditioningPattern` es `White`. Cada fase admite `content: "White"` o `"FromInput"`; si falta, usa el global. El archivo inicial usa blanco en DRY y las primeras dos fases de PREHEAT; usa la entrada de video durante la subida 50→80, estabilización y COOLDOWN. Esta elección es provisional y editable. Cada transición pasa por Blackout → brillo actual/inicial confirmado → patrón seleccionado; no activa blanco a brillo anterior desconocido.

`profileAccepted: true` registra la autorización del operador para la propuesta general. Para control también exige `panelPowerCouplingVerified: true` y `startupProtectionVerified: true`, ambos falsos inicialmente. El primero confirma que la detección por controlador sirve para ese montaje; el segundo confirma protección real durante el tiempo anterior al primer comando. Una lectura TCP no detecta cortes exclusivos de paneles. `profileSource` conserva la procedencia, sin exigir una certificación del fabricante que no existe.

## Horarios de uso y solicitudes

`operatingWindows` empieza vacío para no inventar horas de operación. Ejemplo de formato, no horario preconfigurado:

```json
{"start":"08:00","end":"18:00","days":[1,2,3,4,5]}
```

Días: domingo 0, lunes 1, sábado 6. Si fin es anterior al inicio, termina al día siguiente. Se derivan solicitudes virtuales por fecha local; el precalentamiento empieza cuatro horas antes con la curva inicial, incluso si cruza medianoche. El fin de uso inicia COOLDOWN y después Blackout. No se corta electricidad. Los horarios superpuestos y horas ambiguas/inexistentes por horario de verano fallan explícitamente.

`DataDirectory/solicitudes.json` contiene:

```json
{"schemaVersion":1,"items":[{"id":"3502cb0e-f913-4284-a3de-e4267598a670","title":"Uso solicitado","startUtc":"2026-10-21T17:00:00Z","endUtc":"2026-10-21T18:00:00Z","cancelled":false}]}
```

La GUI exige cuatro horas de anticipación al crear solicitudes. El backend exige GUID único, fechas ISO con zona explícita, fin posterior a inicio, máximo siete días de duración y ninguna superposición entre solicitudes activas. Permite hasta 1000 elementos. Un archivo ausente significa lista vacía; un archivo inválido no se ignora. La GUI debe guardar por sustitución atómica. El uso ya vigente tiene prioridad sobre una preparación futura, tanto en solicitudes como en horarios. Dentro de la misma clase ordena por comienzo; a igualdad de hora prioriza la solicitud explícita. Si un precalentamiento comienza tarde, no pasa a OPERATING hasta completar todas sus fases.

Prioridad en marcha: pregunta al operador/fallo → solicitud u horario de uso → COOLDOWN pendiente → DRY pendiente → BLACK. El calendario puede interrumpir DRY; lo hace mediante Blackout y nivel inicial bajo. Un DRY ya comenzado termina completo salvo interrupción/solicitud. Marca las franjas terminadas para no repetirlas en el mismo proceso; limita la memoria a 256 claves. Una primera conexión fuera de cualquier ventana queda en BLACK y respeta las horas de reposo; no inicia blanco ni DRY fuera de horario. Ningún progreso térmico se restaura desde disco.

## Pregunta después de una interrupción

Tras una pérdida de comunicación posterior a una conexión válida en control, `estado.json` incluye `operatorPending`, `operatorGateId` y `operatorMessage`. El identificador cambia en cada nueva pérdida tras reconectar. Al volver a tener respuestas estables, intenta Blackout y cero, queda en `WAIT_OPERATOR` y congela el calendario.

La GUI escribe atómicamente `operador.json`:

```json
{"id":"798dc024-bf76-4d11-b847-f6951c8f32ac","gateId":"IDENTIFICADOR-ACTUAL-DEL-ESTADO","action":"restart","utc":"2026-10-20T20:00:00Z"}
```

`restart` autoriza un PREHEAT completo desde cero. Solo habilita operación si al terminar sigue vigente una solicitud/horario y ya llegó su inicio; fuera de uso termina negro. `hold` mantiene negro y la pregunta pendiente; el operador puede decidir reiniciar más tarde con otro identificador de comando. Cada identificador se consume una sola vez dentro de la pregunta actual, incluso después de otros comandos o de reiniciar el proceso. Conserva hasta 1024 identificadores por pregunta; superar ese límite termina con fallo retenido y exige inspección explícita. Comandos de pérdidas anteriores no aprueban pérdidas futuras. La metadata pendiente y el último comando consumido sobreviven a reinicios; no se cargan tiempos de progreso.

Si la GUI está cerrada o la tarea corre en sesión SYSTEM sin escritorio, el proceso continúa esperando; no intenta mostrar diálogos desde sesión 0. En monitor no escribe ni exige aprobación para recuperar lecturas.

## Ejecución y estado

```powershell
powershell.exe -NoProfile -File .\Watch-Vx400Plan.ps1 -ValidateOnly
powershell.exe -NoProfile -File .\Watch-Vx400Plan.ps1 -ConfigPath .\plan.config.json -DataDirectory .\plan-data
# Solo con las verificaciones del montaje completadas:
powershell.exe -NoProfile -File .\Watch-Vx400Plan.ps1 -EnableControl -DataDirectory .\plan-data
```

Parámetros: `ConfigPath`, `DataDirectory`, `EnableControl`, `ValidateOnly`, `MaxPolls` (0 ilimitado). Los valores por defecto se resuelven dentro del cuerpo del script para Windows PowerShell 5.1. `ValidateOnly` no crea directorios ni contacta la red.

`estado.json` se sustituye atómicamente en cada sondeo y durante esperas de más de un segundo. Campos: `schemaVersion`, `mode` (`monitor`/`control`), `state`, `communication`, `brightnessRequested`, `phase`, `progressPercent`, `remainingSeconds`, `profileKey`, `updatedUtc`, `lastSuccessfulReadUtc`, `lastEvent`, `operatorPending`, `operatorGateId`, `operatorMessage`, `operatorLastCommandId`, `operatorConsumedCommandIds`, endpoint. El brillo es el último porcentaje cuantizado solicitado con ACK, no una lectura óptica. `eventos.jsonl` registra transiciones, rotando a 1 MiB y conservando cinco archivos anteriores.

Estados: BOOT, WAITING, PREHEAT, OPERATING, DRY, COOLDOWN, BLACK, WAIT_OPERATOR, FAULT, STOPPED. La comunicación es `unknown`, `uncertain`, `unreachable` o `reachable`. Se utiliza el mismo mutex por endpoint que el watcher anterior y un lock de archivo antes de escribir estados/logs. Nunca ejecutar ambos controladores sobre el mismo endpoint.

Crear `DataDirectory/stop.request` solicita parada con Blackout y cero de mejor esfuerzo. El runtime consume y retira el archivo al reconocer la parada; la GUI debe deshabilitar primero cualquier tarea programada si desea impedir el relanzamiento periódico. Cerrar la ventana no detiene el proceso. Antes de modificar la configuración, detener el runtime, esperar su salida y guardar el cambio; el runtime relee las solicitudes cada vuelta, pero la configuración solo al iniciar.

## Diseño, tareas y verificación

La separación es: `Vx400.Schedule.psm1` valida y calcula sin red; `Watch-Vx400Plan.ps1` maneja estado, reloj monotónico, transporte documentado, archivos y pregunta al operador. `Vx400.Protocol.psm1` conserva su contrato y validación estricta de respuesta/checksum. El calendario usa UTC y zona local; los perfiles usan reloj monotónico y descartan tiempo tras lectura fallida o pausa larga. Se comparan reloj UTC y monotónico antes de cada avance/escritura.

Tareas de esta unidad: modelo/validación → decisiones e interpolación → runtime y persistencia → pruebas puras/simulador → documentación. Las pruebas usan perfiles de fracciones de minuto únicamente para acelerar un simulador en `127.0.0.1`; no constituyen una receta física.

```powershell
powershell.exe -NoProfile -File .\tests\Plan.Tests.ps1
```

```text
VX400_POWERSHELL=/tmp/metis-pwsh/pwsh python3 tests/plan_runtime_tests.py
```

Las pruebas deben cubrir 188/240/36 minutos, hitos de curva, Bogotá, medianoche, cancelación/fin, enfriamiento parcial, modo lectura, ACK perdido, desconexión, aprobación pendiente persistida y comandos obsoletos. Windows 5.1 y GUI requieren validación de integración en Windows; no se afirma validación física del VX400.

Rollback de esta unidad: retirar los dos archivos PowerShell, `plan.config.json`, sus dos pruebas y este documento, después de parar la tarea/proceso que los use. No afecta el diagnóstico ni el watcher anterior. No se realizan commits ni despliegues desde esta unidad.

Evidencia local de esta unidad (2026-10-20): pruebas puras del plan, 13 escenarios TCP de loopback definidos (uno específico de cada sistema) y análisis sintáctico de los tres archivos PowerShell aprobados en PowerShell 7.6.7/Linux. Los escenarios incluyen suspensión del proceso, mantenimiento de pregunta tras reinicio y pérdida de ACK de brillo. La prueba SIGSTOP/SIGCONT se omite en Windows porque esa señal no existe allí; su equivalente de suspensión requiere comprobación específica de Windows. La validación de GUI, tarea SYSTEM, ACL y compatibilidad 5.1 corresponde a la integración Windows del paquete.

Los lectores propios de JSON permiten sustitución atómica (`FileShare.ReadWrite | Delete`). La publicación reintenta hasta 750 ms únicamente errores Windows de sharing/lock (32/33), para tolerar lectores externos breves; errores de permisos/disco siguen provocando parada. La regresión de Windows retiene un lector durante 350 ms y comprueba continuidad del monitor sin escrituras de hardware.
