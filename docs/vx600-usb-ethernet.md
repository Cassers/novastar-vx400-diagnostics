# VX600 original: conexión USB o Ethernet

## Probar en el PC del cliente

1. Extraiga el paquete **completo** y abra `Abrir-Control-NovaStar.bat`.
2. En Estado, seleccione **VX600** y **Ethernet** o **USB**. Para una configuración anterior, el modelo se conserva como VX400: cámbielo explícitamente.
3. En el equipo, elija `Communication > LAN Preferred` para Ethernet o `USB Preferred` para USB, especialmente si ambos cables están conectados. USB usa el conector **USB-B** de control; USB-A sirve para cascada.
4. Ethernet: indique IP y puerto TCP 5200. USB: use **Buscar USB** y seleccione el dispositivo; Automático admite uno solo.
5. Pulse **Probar conexión**. Solo lee la identidad. Debe confirmar **VX600 / ModelID 0x620E**. No modifica brillo ni contenido.
6. Tras esa comprobación, use Iniciar monitor, Control manual o Iniciar secado manual. El secado conserva el perfil provisional configurado; no se convierte en una curva certificada al cambiar de controlador.

Elija un transporte por sesión. Detenga el motor antes de guardar otra conexión. No hay cambio automático de USB a Ethernet ni avance de la secuencia tras una pérdida de comunicación.

## NovaLCT y driver USB

Ethernet es directo y no necesita NovaLCT. USB utiliza el driver **libusb0** de NovaStar ya instalado; NovaLCT no necesita permanecer abierto. Cierre las aplicaciones que estén usando ese USB si aparece un error de acceso. La recuperación de nuestra app solo cierra sus propios motores, no NovaLCT ni sus servicios.

El adaptador admite la familia USB `0483:5720`, con configuración 1, interfaz 0/alternativa 0, clase FF/subclase 06/protocolo 50 y un endpoint bulk de entrada y otro de salida. El descriptor no identifica el modelo: siempre se lee el ModelID. La compatibilidad del VX600 físico del cliente y su driver debe comprobarse con Probar conexión.

Si Buscar USB falla o no encuentra dispositivos, el resultado incluye los dispositivos NovaStar/VID0483 que Windows reconoce cuando ese inventario está disponible. Compruebe el cable USB-B, USB Preferred y el driver original. La app carga `libusb0.dll` desde el directorio de sistema de Windows para la arquitectura del proceso; no descarga DLLs, sustituye drivers ni instala filtros. Un driver x86 necesita un proceso x86 y uno x64, un proceso x64.

Fuentes: [manual NovaStar VX600](https://oss.novastar.tech/uploads/2022/02/VX600-All-in-One-Controller-User-Manual-V1.1.0.pdf), [descargas oficiales NovaLCT/driver](https://www.novastar-led.cn/index/downloadcenter/downloaddatacontent/cateID/15/type/software/catename/%E6%98%BE%E7%A4%BA%E5%B1%8F%E8%B0%83%E8%AF%95%E8%BD%AF%E4%BB%B6%2BNovaLCT.html).

## Requisitos verificables

- Cuando se selecciona un modelo, el motor exige su ModelID antes de escribir: VX400 `0x6211`, VX600 `0x620E`; los modelos Pro quedan fuera.
- Cuando una configuración antigua no incluye modelo/transporte, se interpreta como VX400/Ethernet y conserva fases, tiempos y registros.
- Cuando hay varios USB compatibles y no existe selección explícita, se rechaza el envío. Una selección automática queda fijada en memoria durante la ejecución.
- Antes de cada escritura USB se vuelve a verificar la identidad sobre el mismo handle que enviará el mando. Un equipo diferente o una respuesta inválida impide la escritura.
- Cuando cambia modelo, transporte o destino en la GUI, las comprobaciones de alimentación y arranque se vuelven a solicitar para esa instalación.
- Las pruebas de conexión y descubrimiento no ejecutan mandos de brillo/contenido. El motor conserva ACK, checksum, correlación, frescura, exclusión y decisión pendiente tras pérdida.

## Diseño e interoperabilidad

`Vx.Connection.psm1` normaliza la configuración y selecciona el transporte. Ethernet conserva el protocolo y la clave de exclusión IP:puerto anteriores. USB reserva `USB:LOCAL`: solo un motor USB de esta app por PC, aunque haya varios dispositivos conectados.

`Vx.Usb.Native.cs` usa la ABI pública de [libusb-win32](https://github.com/mcuee/libusb-win32/blob/master/libusb/src/lusb0_usb.h), con estructuras Pack=1 y funciones Cdecl. La capa USB usa envolturas USBC/A2/A3; no envía TCP crudo al puerto USB. La respuesta NovaStar se valida además mediante checksum, secuencia, dirección, longitud y ModelID. El código se escribió para interoperabilidad; no se distribuyen DLLs propietarias.

La evidencia de envoltura procede del binario de NovaStar públicamente rehosteado [Nova.IO.Communication.UsbController.dll](https://github.com/alstergee/novastar-win11-fix/blob/main/MarsServerProvider_Fixed/Nova.IO.Communication.UsbController.dll), versión 1.0.1902.2601, SHA256 `b124ff8276036e85f534c5c89bfd2e88582e15bc7fe0dc88ed0287db52c077a9`. El adaptador admite la respuesta AA55 directa y la ruta de estado USBS seguida de lectura A3, con estado/tag/residuo comprobados. Otros modos USB o descriptores requieren una adaptación comprobada.

El tiempo límite se comparte entre transferencias bulk. Las funciones nativas de descubrimiento/apertura/configuración no tienen parámetro de timeout; se comprueba el tiempo transcurrido alrededor de ellas. Las operaciones de la GUI se ejecutan en un proceso hijo.

## Plan y validación

- [x] Modelo y transporte con compatibilidad de configuraciones anteriores.
- [x] Intercambio USB real, selección y verificación de identidad.
- [x] Selector gráfico, búsqueda y prueba de lectura.
- [x] Instalación con todos los módulos y exclusión/recuperación USB.
- [x] Pruebas locales contra simulador e IO inyectada, incluidas respuestas inválidas y sustitución de dispositivo.
- [ ] Aceptación en el VX600 físico por cada transporte.

La CI de cada commit comprueba Windows PowerShell 5.1 y genera capturas de la interfaz; consulte la ejecución vinculada en la release. La simulación comprueba software y formato; no acredita un intercambio físico USB ni deshumidificación. Para revertir, utilice el paquete v0.5.0 con una configuración VX400/Ethernet compatible; retire las tres propiedades de conexión nuevas si vuelve al validador anterior. Conserve datos y decisiones pendientes.
