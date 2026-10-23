# Salida multimedia de Usuarios

Pro configura la carpeta local (por ejemplo `Escritorio\PANTALLA`), vídeo, imagen NEGRO y nombre exacto de pantalla de Windows. La salida comienza sin seleccionar. La pantalla principal necesita aceptación explícita con `allowPrimaryScreen=true`. No se cambian resoluciones, modos de Windows ni configuración del monitor.

`Play-VxOperatorMedia.ps1` se ejecuta en un proceso separado de la interfaz, con Windows PowerShell 5.1 `-STA`, en la misma sesión interactiva del motor. Usa WPF MediaElement alojado en WinForms mediante ElementHost; la imagen usa PictureBox. El marco nativo de Windows debe estar disponible. No instala componentes, códecs ni reproductores y no usa un navegador como sustituto. La disponibilidad del códec depende del Windows instalado y del contenido real del archivo.

El vídeo se repite sin audio ni controles; `Stretch.Uniform` conserva la proporción con márgenes negros. La imagen también conserva proporción. El formulario sin bordes usa los `Screen.Bounds` de la pantalla elegida, sin autoescalado WinForms; el host WPF rellena ese formulario. Se debe aceptar la colocación real en Windows con el escalado/DPI instalado antes de conectar la salida al procesador.

## Validación sin salida física

```powershell
.\Play-VxOperatorMedia.ps1 -OperatorConfigPath .\operator.config.json -ValidateOnly
.\tests\OperatorMedia.Tests.ps1
```

`ValidateOnly` comprueba aceptación del perfil y rutas; no abre ventanas, enumera pantallas ni prueba códecs. Las pruebas usan archivos temporales y comandos sintéticos. En Windows compilan las referencias WPF/WinForms sin crear una ventana. Un archivo `.mp4` válido por extensión todavía puede fallar al decodificar.

`-SmokeTest` permite solamente una vista previa desechable de imagen de 320×180, sin pantalla completa ni topmost. Requiere un directorio de datos de pruebas aislado y UUID de sesión; no requiere motor. No usar el directorio de un motor activo. Su resultado confirma enlace nativo/imagen; no demuestra reproducción de vídeo ni colocación física.

## Contrato y fallo seguro

El motor invoca `-OperatorConfigPath PATH -DataDirectory PATH -SessionId UUID`. Escribe atómicamente `operator-media.json` con `schemaVersion:1`, `id`, `sessionId`, `utc` y `mode` (`Video`, `Black`, `Input` o `Stop`). El helper publica `operator-media-state.json` con `schemaVersion`, `id`, `sessionId`, `updatedUtc`, `success`, `mode`, `message`.

`Video` obtiene ACK positivo después de `MediaOpened`, dimensiones de vídeo y avance real de `Position`. Abrir el nombre del archivo no basta. No publica ACK coincidente mientras abre; un fallo o tiempo de espera de 8 segundos publica `success:false`. En reproducción se actualiza el mismo ACK cada segundo. El motor debe mantener BLACK y brillo bajo hasta ese ACK; el helper nunca manda comandos al hardware. `Black` confirma después de cargar/decodificar y pintar la imagen. `Input` oculta la salida para la fuente en vivo existente; `Stop` confirma y termina.

Las órdenes nuevas requieren UUID, sesión vigente, campos exactos y antigüedad máxima de 10 segundos (2 segundos de tolerancia futura). Se rechazan repeticiones y modos desconocidos. Una orden ya aceptada mantiene el bucle aunque su fecha envejezca. El helper exige que `operator-state.json` siga fresco (10 segundos), con la misma sesión y PID vivo. Si desaparece pantalla/archivo, cambia sesión, falla el decodificador o deja de avanzar el vídeo, oculta su ventana y publica error. No reanuda automáticamente. Un mutex local evita dos helpers sobre el mismo directorio.

Solo se aceptan archivos locales absolutos dentro de la carpeta configurada: vídeo `.mp4/.wmv/.avi/.m4v/.mov`; imagen `.png/.jpg/.jpeg/.bmp`. Se rechazan URL, UNC, unidades de red y enlaces/junctions/reparse points detectables. La carpeta debe permanecer bajo control del operador: la validación no reemplaza permisos de Windows ni impide una sustitución concurrente maliciosa de archivos.

Cerrar Usuarios deja motor/helper activos. Cerrar sesión, suspender o retirar la pantalla interrumpe la operación multimedia; las comprobaciones no certifican que un panel físico esté mostrando la imagen. Aceptación pendiente: códec real, vídeo en bucle, pantalla elegida/DPI, pérdida de pantalla y protocolo seguro con el hardware del cliente.

Referencias: [control manual y eventos MediaElement](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/how-to-control-a-mediaelement-play-pause-stop-volume-and-speed), [alojamiento WPF en WinForms](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/walkthrough-hosting-a-wpf-composite-control-in-windows-forms).
