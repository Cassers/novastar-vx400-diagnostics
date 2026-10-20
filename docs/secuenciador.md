# Secuenciador permanente por Ethernet

## Requisitos

El PC permanece en el sitio. El operador necesita registrar pérdidas de comunicación con el VX400 y ejecutar una secuencia completa al volver a responder, sin intervenir en NovaLCT.

- R1: al iniciar el proceso, consultar ModelID mediante el protocolo TCP documentado; solo aceptar VX400 0x6211. No usar ping como prueba de alimentación.
- R2: tras fallos consecutivos, registrar `sin_comunicacion`; al recuperar respuestas consecutivas, registrar `comunicacion_recuperada`. Una primera lectura correcta se registra como conexión inicial, sin inventar un apagado anterior.
- R3: en modo monitor, no enviar escrituras. En modo secuencia, ejecutar también al conectar inicialmente, ya que no sabemos cuánto tiempo estuvieron apagados los paneles.
- R4: antes de mostrar un patrón, enviar Blackout y el primer brillo. Ejecutar etapas en orden, cronometradas con reloj monotónico; finalizar con Blackout, brillo normal y modo Normal. Un ACK no prueba efecto óptico o térmico.
- R5: ante cualquier fallo de lectura durante una etapa, interrupción larga del proceso o ACK perdido, abandonar el ciclo; intentar Blackout y brillo cero. No avanzar al contenido tras un error. Un fallo de escritura durante los pasos del ciclo queda retenido hasta reiniciar el programa. Si el equipo está apagado/inaccesible, los intentos de oscurecer también pueden fallar: la recuperación estable exige entonces nuevos ACK de Blackout y primer brillo antes del patrón, siempre desde cero.
- R6: ninguna etapa se reanuda desde un estado guardado. Una instancia por endpoint; escribir estado legible y diario con rotación. Si falla el almacenamiento, intentar oscurecer y salir con error.
- R7: instalación opcional como tarea de arranque de Windows, sin sesión interactiva, con archivos protegidos y relanzamiento periódico si muere el proceso. No cambiar suspensión, firewall, drivers ni firmware.
- R8: el paquete por defecto solo monitoriza. Las escrituras requieren habilitación explícita y perfil con curva, alimentación conjunta y protección del primer encendido verificadas. No suministrar receta térmica universal.

## Diseño

`Watch-Vx400.ps1` usa `Vx400.Protocol.psm1`, sin comandos adicionales ni sondeo de registros desconocidos. `Vx400.Automation.psm1` valida configuración y describe acciones por etapa. JSON configura endpoint, sondeo, umbrales y curva. La tarea ejecuta el mismo programa bajo SYSTEM; código y configuración en Program Files, estado y diario en ProgramData con permisos limitados a SYSTEM/Administradores. No hay servidor web ni dependencia externa.

Estados: `iniciando`, `esperando`, `conectado` (monitor), `acondicionando`, `contenido`, `sin_comunicacion`, `fallo`, `detenido`. El archivo de estado describe comunicación; nunca afirma que la pantalla esté eléctricamente apagada. En cada recuperación estable se exige nueva secuencia. Tras error de escritura no se reintenta automáticamente una curva con resultado incierto.

Los intervalos y timeouts son configurables. La pérdida de un solo sondeo durante un ciclo invalida el ciclo; el umbral de tres fallos solo reduce ruido del registro de conexión. Los saltos largos de tiempo/suspensión también invalidan el ciclo. El controlador no detecta cortes exclusivamente de paneles ni garantiza oscuridad si el PC/red falla. El montaje requiere una protección física o comportamiento de arranque comprobado para cubrir el tiempo antes del primer comando.

## Verificación y tareas

- [x] Validación estricta del JSON y plan de comandos; objetivo PowerShell 5.1, comprobación en CI.
- [x] Monitor, secuencia, recuperación y registro incremental.
- [x] Instalación y desinstalación de tarea Windows; smoke test en CI.
- [x] Simulador TCP: modo lectura, reconexión, orden y duración de etapas, ACK perdido, error de disco, perfil inválido, suspensión y exclusión mutua.
- [ ] CI Windows y paquete público de código propio.
- [ ] Pendiente en sitio: curva apropiada, conmutación de paneles, comportamiento antes del PC, cada salida/receptora y pruebas de corte/red/proceso.

## Fuentes

- [Protocolo oficial VX400 V1.0](https://wpan.novastar.tech/v2/sharing/818d1143ec32ffd5a545c19181).
- [Manual VX400 V1.3.0](https://oss.novastar.tech/uploads/2025/06/VX400-All-in-One-Controller-User-Manual-V1.3.0.pdf).
- [Microsoft: tareas al iniciar Windows](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasktrigger).
- [Microsoft: comportamiento de tareas](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset).
