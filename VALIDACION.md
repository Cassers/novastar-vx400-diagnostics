# Evidencia de validación

2026-10-20. No se conectó este diagnóstico a un VX400 real.

- PowerShell 7.6.7 portátil oficial, Linux: análisis de sintaxis y ejecución de inventario correctos.
- `tests/Protocol.Tests.ps1`: 18 aserciones correctas, incluyendo tramas oficiales, checksum, correlación, respuestas truncadas y decodificación de entradas.
- `tests/runtime_tests.py`: 7 escenarios correctos contra servidor simulado local: solo lectura por defecto, identidad inválida que bloquea escrituras, fragmentación TCP, pruebas activas/restauración, respuesta perdida tras escritura, fallo de restauración que impide volver a Normal y rechazo de pruebas sin habilitación explícita.
- La prueba inicial del simulador dentro del sandbox no pudo crear sockets; se repitió con permiso exclusivamente para loopback. No se interpretó esa restricción como un defecto del diagnóstico.
- Revisión estática independiente del BAT, protocolo, atribución de firmware y recuperación. Se corrigieron: presupuesto de tiempo de comandos activos, logging que podía interrumpir restauración y una afirmación no documentada sobre persistencia RAM.
- Windows PowerShell 5.1: CI incluida en `.github/workflows/test.yml`; consultar el resultado del commit publicado para la evidencia de ejecución en Windows. El control UI Automation con NovaLCT real y la ejecución del BAT por doble clic requieren el PC del sitio.

Retirada: eliminar esta carpeta y sus informes. No se instala un servicio, tarea programada ni configuración de arranque. Las pruebas de lectura no modifican el dispositivo. Si se ejecutaron pruebas activas, confirmar brillo/modo originales en el equipo y revisar `restoration` antes de retirar el diagnóstico.
