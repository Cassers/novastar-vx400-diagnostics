# VX600 Pro: diagnóstico de identidad Ethernet, soporte parcial

La app v0.8.3 mantiene soporte operativo para los VX400/VX600 originales. **Este diagnóstico prepara el soporte VX600 Pro: no habilita el control Pro ni demuestra compatibilidad de brillo, capas, pantalla o USB.** No modifica la aplicación ni sus claves/configuraciones y no requiere administrador.

Extraiga el ZIP de diagnóstico completo en una carpeta aparte. Abra `Diagnosticar-VxProIdentidad.bat`, introduzca la IPv4 del equipo y espere el resultado. Usa Ethernet TCP **15200** por defecto y efectúa una sola lectura ModelID de dos bytes, dirección `0x00000002`. No busca equipos, no cambia brillo/contenido, no guarda configuración en el dispositivo y no envía escrituras. Los scripts incluidos se desbloquean para esta ejecución sin cambiar la política de Windows. No se requiere instalar Python.

El informe JSON se guarda en `%LOCALAPPDATA%\NovaStar\diagnostics\` con nombre único. La consola indica la ruta, la solicitud/respuesta hexadecimal, el ID de 16 bits observado o el error. No se sube automáticamente. Una respuesta correcta significa únicamente que pasó checksum y correlación; muestra **identidad sin correspondencia de modelo verificada; control NO habilitado**. Ningún valor de ModelID se identifica por suposición como VX600 Pro.

Opcional desde Windows PowerShell 5.1 después de preparar los archivos con el BAT:

```powershell
.\Diagnosticar-VxProIdentidad.ps1 -DeviceAddress 192.0.2.10 -TcpPort 15200 -TimeoutMs 3000 -OutputPath "$env:TEMP\vx-pro-informe-nuevo.json"
```

La IP del ejemplo es ilustrativa: use la del equipo. `OutputPath` debe ser un archivo nuevo en una carpeta existente; jamás se sobrescriben archivos. El plazo total de conexión/respuesta es finito (3 segundos por defecto; 250–15000 ms permitidos); la respuesta está limitada por el lector estricto a 4116 bytes. Código de salida 0 indica lectura válida, 2 indica fallo de lectura o exportación, nunca soporte operativo habilitado.

Comparta el JSON, el ModelID bruto, una foto de la etiqueta física del equipo y su versión de firmware consultada manualmente en el dispositivo. El diagnóstico no consulta firmware. Esa evidencia permite vincular el ID al modelo real; después harán falta pruebas controladas de banco y ACK de las operaciones antes de habilitar control. No cambie modelos/configuraciones de la app para saltarse su identificación estricta.

## Fundamento y límites

- [Producto oficial VX600 Pro](https://www.novastar.tech/product/detail.html?catid=3&id=34).
- [Manual oficial VX Pro V1.4.2](https://en-website001.oss-us-east-1.aliyuncs.com/Specification/VX%20Pro%20Series%20All-in-One%20Controller%20User%20Manual-V1.4.2.pdf), §§7.1.1–7.1.2: control Ethernet.
- [Protocolo fabricante VX Pro V1.0.5, 2025-10-10](https://github.com/user-attachments/files/25436675/VX.Pro.Series.Control.Protocol.V1.0.5.pdf), §3.1.2, p.7: TCP15200, lectura ModelID dirección2/longitud2; declarado para VX400/600/1000/2000 Pro, versión de dispositivo1.2.0. No proporciona un mapeo fiable ID→modelo ni una consulta de firmware. Los ejemplos no acreditan identidad física.

No se reutilizan escrituras de la familia original: existen diferencias de direcciones y ejemplos de ACK/capas pendientes de resolver. El puerto USB físico no acredita VID/PID, endpoints ni encapsulación compatible. La evidencia automatizada usa únicamente loopback, respuestas sintéticas y BAT/PowerShell nativos; no constituye prueba de un controlador físico.
