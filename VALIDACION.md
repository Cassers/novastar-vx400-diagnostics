# Evidencia de validación

2026-10-20. Pruebas automatizadas ejecutadas exclusivamente en simuladores; la ejecución física del diagnóstico fue realizada por el operador del sitio, según captura recibida. El nuevo secuenciador no ha enviado escrituras a hardware real.

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
