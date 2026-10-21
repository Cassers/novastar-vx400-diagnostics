# Recuperar el control local del VX400

## Requisitos

- Al intentar recuperar el control, la app identificará nuestros motores locales para la misma IP y puerto, incluso desde otra carpeta o sesión de Windows.
- Mostrará PID y ruta. Rechazará comandos ambiguos, ejecutables ajenos, scripts desconocidos y configuraciones para otro equipo.
- Intentará una parada normal y pausará únicamente el inicio automático cuya pertenencia y destino haya verificado.
- Si quedan procesos, ofrecerá Forzar cierre como acción explícita. Un cambio de propietario entre la detección y el clic requiere revisar la lista nueva.
- No cerrará NovaLCT, otros PowerShell ni clientes de otro computador. No ampliará permisos del bloqueo global.
- Conservará configuraciones, solicitudes, registros y decisiones pendientes. No reanudará secuencias. La parada ordenada del controlador puede intentar negro y brillo cero.

## Diseño

`Vx400.Ownership.psm1` identifica procesos mediante ejecutable real, argumentos, hash del script, configuración del endpoint y fecha de creación. El cierre verifica de nuevo la identidad y conserva un handle al proceso para evitar actuar sobre un PID reutilizado. `Recover-Vx400.ps1` ejecuta la recuperación fuera del hilo de la GUI y devuelve JSON; no envía paquetes al VX400.

Control manual contiene Recuperar control, una lista de resultados y Forzar cierre cuando quedan candidatos revisados. Si hace falta elevación, se vuelve a abrir la misma GUI y contexto mediante UAC. La exclusión global sigue activa: recuperar nunca equivale a ignorar un bloqueo o matar todos los PowerShell.

La parada ordenada de un controlador activo puede intentar Blackout y brillo cero. Tras éxito la salida anterior no queda confirmada. El operador elige Mostrar negro o inicia una secuencia nueva. Forzar cierre interrumpe también un secado activo; su progreso no se recupera.

## Tareas y verificación

- [x] Identificación estricta y recuperación normal/forzada con snapshot de propietarios.
- [x] Interfaz asíncrona, elevación y resultados visibles.
- [x] Instalación copia los nuevos archivos y conserva datos.
- [ ] Pruebas de rechazo de procesos ajenos y escenarios nativos Windows sin hardware.
- [ ] Empaquetado y publicación de v0.5.0 tras validación.

Comprobado localmente: 32 aserciones de identificación, rechazo de comandos ajenos y preservación de peticiones existentes/enlaces duros; sintaxis PowerShell. La ejecución de CIM, cierre por handle, elevación y WinForms en Windows está pendiente: el acceso a GitHub para la CI no estuvo disponible durante la preparación. El paquete local se identifica como candidato.

Reversión: retirar botones/worker/módulo de recuperación y sus pruebas; la exclusión y el motor de secuencias siguen funcionando. El arreglo de resultados asíncronos es independiente y se conserva.
