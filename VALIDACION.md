# Evidencia de validación

2026-10-22. Pruebas automatizadas ejecutadas exclusivamente en simuladores; la ejecución física del diagnóstico fue realizada por el operador del sitio, según captura recibida. El nuevo secuenciador no ha enviado escrituras a hardware real.

## Ampliación VX600 y USB/Ethernet v0.6.0

- Selección de modelo y transporte; configuraciones anteriores VX400/Ethernet y nuevas VX600/Ethernet.
- Pruebas de ambos modelos contra TCP loopback: monitor, mandos manuales, secado completo, identidad incorrecta o cambiada, ausencia de escrituras ante configuración inválida.
- Prueba de lectura en un proceso real: VX400/VX600 correctos, modelo erróneo y exclusión con un monitor activo.
- USB usa pruebas de la implementación C# con IO inyectada: envolturas, fragmentación, rutas directa/A3, checksum de identidad, tag/estado/residuo, errores, plazos, selección y cambio de dispositivo. Estas pruebas no cargan un driver Windows ni acceden a USB físico.
- Revisión independiente: corregida la posibilidad de cambiar automáticamente de dispositivo entre paquetes y el arrastre de confirmaciones de instalación al seleccionar otro USB.
- Pendiente: aceptación del driver y descriptores del VX600 real, intercambios físicos por USB/Ethernet y efecto térmico del perfil provisional. Las pruebas simuladas no acreditan esos resultados.

## App nativa y plan v0.5.0

- Recuperación local: 40 aserciones en Windows PowerShell 5.1. Identidad, argumentos ambiguos/ajenos, rutas relativas, configuración modificada, endpoint, hashes, tarea propia y peticiones existentes/enlaces duros. Escenario con procesos reales en Windows: parada normal, cierre por handle tras revisar snapshot, rechazo de propietario nuevo, cierre de motor iniciado como SYSTEM y liberación de mutex. Solo loopback; ninguna escritura al hardware.

- 280 aserciones puras del plan: tiempos 188/240/36 minutos, rampas fraccionarias, punto del 15%, zona Bogotá, medianoche, horarios semanales, solicitudes, cancelaciones y prioridad operación sobre preparación futura.
- 23 escenarios definidos de ciclo de vida contra TCP loopback (uno específico de Windows y uno de Unix): solo lectura, reposo fuera de horario, secado programado, preparación completa antes de operar, bajada tras fin/cancelación, respuestas perdidas, pregunta al operador, decisión pendiente conservada al reiniciar, rechazo de respuestas antiguas, suspensión del proceso y consumo de petición de parada y lectura concurrente del estado en Windows.
- 13 aserciones adicionales del generador de rampa del motor anterior, sin red. La plantilla de 70 minutos conserva niveles pendientes; no se usa como algoritmo térmico certificado.
- Regresión de resultado asíncrono: procesos PowerShell reales y sin hardware producen éxito para negro/blanco/entrada, fallos con stderr/stdout o sin detalle, y salida normal de controlador/instalador. Se comprueba que no haya falso error por ExitCode vacío y que los fallos reales queden en Registro.
- La GUI dispone de smoke test Windows PowerShell 5.1/WinForms: guardado válido, rechazo sin corromper configuración, creación/cancelación/solapamiento de solicitudes, estado obsoleto y pregunta pendiente. Genera seis capturas para revisión visual. Los stubs detectan cualquier arranque accidental del controlador o instalador.
- Smoke test de instalación en runner Windows desechable: ACL privadas, SYSTEM, actualización propia, retirada/restauración y conservación/migración de decisión pendiente. No ejecuta escrituras contra un dispositivo real.
- Nuevas regresiones de mandos manuales: ACK de brillo antes de contenido, ACK perdido sin habilitar blanco/entrada, exclusión por endpoint, secado manual de una ejecución, cancelación sin reinicio, respuesta de identidad suspendida y rechazo de cambio de brillo durante secado.
- Revisión independiente entre autores de GUI y backend. Se corrigieron protección de tarea por ruta/acción, migración entre carpetas, recuperación sin bloquear por fallos esperables de ACK con equipo apagado, consumo de parada, prioridades y sobrecarga entera de Math.Min/Max en PowerShell.
- Pendiente en sitio: comportamiento físico del equipo y paneles, permisos del PC real, primer fotograma, pruebas completas de alimentación y aceptación térmica del perfil provisional. No se instala ni controla nada en el PC remoto desde estas pruebas.

## Monitor/secuenciador v0.2.0

- Pruebas locales PowerShell 7.6.7: monitor de solo lectura, pérdida/recuperación, orden y duración mínima de etapas, nuevo ciclo desde cero, ACK perdido, identidad distinta, perfil sin aprobar, curva descendente, protección inicial no verificada, fallo de disco, exclusión por endpoint y pausa entre lectura/transición.
- Revisión independiente de recuperación, suspensión y privilegios del instalador. Se corrigieron canonicalización IPv4 antes del mutex, registros escritos por un proceso que perdió el mutex, comprobación de frescura antes de escrituras y conservación del estado de fallo tras interrupciones.
- CI Windows PowerShell 5.1 ejecuta estas pruebas, las anteriores del diagnóstico y un smoke test de instalación: ACL protegidas, tarea SYSTEM, disparadores, rechazo de perfil activo incompleto y colisiones, retirada conservando registros. El test solo registra/retira una tarea contra loopback en un runner desechable; no la arranca ni hace pruebas térmicas.
- Pendiente de aceptación física: cualquier escritura real, todas las receptoras/salidas, curva apropiada, entrada de vídeo/patrón, alimentación y primer fotograma, corte de paneles separado del VX400, suspensión/cortes/red/fallo del PC y arranque Windows real tras pérdida de corriente. La presencia de pruebas/ACK no demuestra deshumidificación.

## Diagnóstico v0.1.0

- PowerShell 7.6.7 portátil oficial, Linux: análisis de sintaxis y ejecución de inventario correctos.
- `tests/Protocol.Tests.ps1`: 18 aserciones correctas, incluyendo tramas oficiales, checksum, correlación, respuestas truncadas y decodificación de entradas.
- `tests/runtime_tests.py`: 7 escenarios correctos contra servidor simulado local: solo lectura por defecto, identidad inválida que bloquea escrituras, fragmentación TCP, pruebas activas/restauración, respuesta perdida tras escritura, fallo de restauración que impide volver a Normal y rechazo de pruebas sin habilitación explícita.
- La prueba inicial del simulador dentro del sandbox no pudo crear sockets; se repitió con permiso exclusivamente para loopback. No se interpretó esa restricción como un defecto del diagnóstico.
- Revisión estática independiente del BAT, protocolo, atribución de firmware y recuperación. Se corrigieron: presupuesto de tiempo de comandos activos, logging que podía interrumpir restauración y una afirmación no documentada sobre persistencia RAM.
- Windows PowerShell 5.1: CI incluida en `.github/workflows/test.yml`; consultar el resultado del commit publicado para la evidencia de ejecución en Windows. El control UI Automation con NovaLCT real y la ejecución del BAT por doble clic requieren el PC del sitio.

Retirada del diagnóstico puntual: eliminar esta carpeta y sus informes. Ejecutar únicamente `Diagnosticar-VX400.bat` no instala tareas ni configuración de arranque. La instalación permanente opcional se retira con `Quitar-Monitor-VX400.bat`, conservando archivos. Las pruebas de lectura no modifican el dispositivo. Si se ejecutaron pruebas activas del diagnóstico, confirmar brillo/modo originales en el equipo y revisar `restoration` antes de retirarlo.
