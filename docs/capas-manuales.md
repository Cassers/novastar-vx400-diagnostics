# Capas manuales del VX600 original

## Prueba en sitio

1. Termine o detenga cualquier secado, monitor o calendario y espere la confirmación. Detener pausa el inicio automático y puede llevar la salida a negro y brillo cero.
2. Guarde el modelo VX600 y su conexión en Estado. Para USB, busque y seleccione el equipo concreto.
3. Entre en Control manual. Desplace la página hasta MAIN / PIP1 / PIP2 y pulse Leer capas. La consulta no modifica el vídeo ni el brillo.
4. Anote los tres estados. Desactive y reactive una capa que ya tenga fuente y geometría configuradas; compruebe que solo esa capa cambia. Con negro global activo o brillo cero no se verá la composición: el estado por protocolo no equivale a una comprobación visual.
5. Verifique entrada, posición y tamaño antes/después con el equipo. Repita la prueba por el otro transporte con el motor detenido. No desconecte el cable durante el mando.
6. Para volver al calendario seleccione Iniciar control. Los mandos de capas no lo reanudan automáticamente.

Los controles no están disponibles para VX400 ni modelos Pro. MAIN/PIP son capas de vídeo independientes, no modos mutuamente excluyentes: pueden estar activas varias a la vez. El encendido de una capa no cambia el patrón global negro/blanco/entrada. MAIN con MOSAIC no puede coexistir con PIP activas. En modo ByPass las PIP no están disponibles; no se cambia el modo de trabajo desde este panel.

No se inicializan fuentes ni dimensiones vacías para conseguir que se active una capa. Si la configuración no permite activarla, se informa del rechazo. Para configurar entrada, tamaño o posición se necesita la configuración del equipo u otra herramienta compatible.

## Fuente y conservación de ajustes

Se utiliza el documento de NovaStar **VX600 Control Protocol V1.1, 25-08-2022**, sección 3.4.2, páginas impresas 9–10: [documento del fabricante alojado por un distribuidor](https://www.ezledvisual.com/storage/file/20240926/1727345641282825.pdf). La sección 3.4.1 usa otra dirección para cambiar la fuente; no sirve como comando ON/OFF.

El comando documentado de activación incluye todos los parámetros de la capa. Se solicita primero el bloque actual de 48 bytes y se conserva completo, modificando únicamente Switch. La lectura usa el mecanismo general de registros; la disponibilidad de esa lectura completa debe comprobarse en el firmware real. No se envían parámetros por defecto cuando no se puede leer. Se comprueba identidad VX600, checksum y correlación de cada respuesta. El ACK se complementa con lectura posterior; si no coincide, el resultado queda sin confirmar y no se emiten mandos compensatorios de brillo o contenido.

El [manual oficial VX600 V1.5.0](https://oss.novastar.tech/uploads/2025/06/VX600-All-in-One-Controller-User-Manual-V1.5.0-1.pdf) describe las capas en §5.3 y las restricciones de MOSAIC/ByPass. También documenta bloqueo/desbloqueo frontal manteniendo perilla y ESC al menos 3 segundos. Nuestra app no envía un comando de bloqueo/desbloqueo y no garantiza impedir ajustes desde otros clientes o desde el panel físico. El bloqueo de brillo de la aplicación durante una secuencia no sustituye una restricción física de acceso al equipo.

## Verificación de software

- `tests/Layer.Tests.ps1`: tramas, validación y conservación del bloque original.
- `tests/layer_runtime_tests.py`: script real contra servidor TCP simulado, identidad, exclusión, rechazos y lectura posterior.
- `tests/Gui.Tests.ps1`: estados y handlers de las tres capas, bloqueo con motor activo, cambio de destino y errores asíncronos usando fixtures sin hardware.
- `tests/GuiHandoff.Tests.ps1`: función de exclusión real en procesos separados; duplicado rechazado, relevo con espera y tiempo límite.

Los ensayos de software no validan el tratamiento térmico ni certifican un bloqueo físico de la perilla. Ninguna prueba automatizada se conecta al equipo del cliente.
