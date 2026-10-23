# Configurar Usuarios desde Pro

Abra **Abrir-Control-Pro.bat** o **Usuarios → Acceso Pro…** e introduzca la clave Pro. La clave temporal exige elegir una nueva de al menos 12 caracteres antes de abrir los ajustes. Puede cambiarla después en **Pro → Estado → Cambiar clave Pro**. Cancelar conserva los archivos y deja Pro cerrado. Pro conserva la interfaz avanzada y añade **Estado → Configurar Usuarios**. Usuarios utiliza `plan.config.json` para la conexión y `operator.config.json` para su perfil diario separado; guardar este último conserva el calendario avanzado.

## Primera puesta en marcha

1. En Pro → Estado, seleccione VX600 original y USB o Ethernet. Pruebe la identidad y guarde. Compruebe físicamente las condiciones de arranque antes de marcar sus verificaciones.
2. Detenga los motores para esa conexión y abra **Configurar Usuarios**. Ajuste ventana diaria, rampas, nivel de reposo, topes y duración de preparación/enfriamiento. Los valores iniciales son provisionales: 04:00–06:00, secado hasta30%, reposo10%, preparación hasta25% durante240min y enfriamiento36min.
3. En **Multimedia y salida**, seleccione carpeta, vídeo, imagen NEGRO y una pantalla de Windows conectada. No se elige la principal por defecto; ocuparla requiere aceptación explícita. La salida del PC debe alimentar una fuente activa del VX600: compruébelo en sitio antes de operar. El selector no configura el cableado ni cambia entradas del controlador.
4. Para SCALE, indique ancho/alto reales del lienzo. Con cero queda deshabilitado. El mando cambia geometría de la capa activa única de menor prioridad, preserva el resto y verifica los tres bloques; no usa un comando nativo SCALE supuesto.
5. Marque la aceptación del perfil y pulse **Validar y guardar**. Abra **Usuarios**. Solo se habilitan órdenes con identidad, propietario y estado recientes.

Si se deshabilita multimedia expresamente desde Pro, el motor utiliza el patrón de acondicionamiento configurado en el plan avanzado. No es una sustitución automática ante fallos del vídeo. Los perfiles se validan antes de guardar; un error conserva el archivo anterior. Detenga los motores antes de cambiar conexión/perfil.

## Entregar al cliente

En el configurador, **Entrega e inicio → Exportar instalación** crea una carpeta completa nueva y vacía con la configuración actual. Incluye Usuarios, Pro y el verificador de la clave configurada para esa instalación. Excluye comandos pendientes, registros y datos de ejecución. Los medios conservan sus rutas; no se empaquetan automáticamente archivos privados/grandes.

Para configurar esa copia posteriormente: **Pro → Estado → Otra instalación Usuarios**, seleccione su carpeta, ajuste conexión y abra Configurar Usuarios en ese contexto. Todos sus ajustes se guardan allí. Conservar una Pro separada no sincroniza automáticamente otra carpeta.

Se entrega un único ZIP con `Abrir-NovaStar.bat` (Usuarios por defecto), ambos lanzadores y los ajustes iniciales sin aceptar. El configurador también pide clave si se abre directamente. La contraseña se entrega por separado; no va en el ZIP ni en el código fuente.

`pro-access.json` se guarda junto al plan de cada instalación y contiene un verificador con sal aleatoria. Pro no abre si falta o está dañado. Copiar una instalación copia su clave; no sincroniza cambios posteriores entre carpetas. La clave limita el acceso desde las interfaces; los scripts editables y archivos portátiles requieren permisos de Windows si se necesita impedir modificaciones por fuera de la app.

## Inicio automático

En **Entrega e inicio**, active **al iniciar sesión**. La tarea usa el usuario actual, permisos limitados y una única activación al entrar en Windows; no guarda contraseñas, no reinicia tratamientos fallidos y no ejecuta multimedia como SYSTEM. Instalarla no arranca el motor inmediatamente: abra Usuarios para empezar ahora.

Quite primero el inicio avanzado Pro para esa conexión. La instalación Pro bajo Program Files/ProgramData protege sus archivos para administradores; el inicio limitado de Usuarios rechaza esas rutas. Exporte una copia a una carpeta accesible del usuario y configúrela desde **Otra instalación Usuarios**. No mueva esa carpeta después de registrar su tarea.

Cerrar la GUI deja motor/reproductor activos. Cerrar sesión, dormir o apagar el PC impide multimedia. **Quitar inicio Usuarios** elimina solo la tarea: conserva perfil/datos y deja el motor actual hasta solicitar parada en Soporte.

## Actualizar y comprobar

Detenga motores y retire su inicio temporalmente. Conserve `plan.config.json`, `operator.config.json`, `pro-access.json` y `plan-data` completos: el historial diario y las decisiones pendientes evitan repetir una secuencia. Extraiga el paquete completo; no mezcle actualizaciones parciales. Restaure los archivos/datos conservados, valide desde Pro y vuelva a habilitar el inicio elegido.

Antes de entregar, pruebe en Windows: reproducción en la salida seleccionada, códec del vídeo, NEGRO, cierre/reapertura, preparación completa, apagado sin aumento de brillo, pérdida de enlace y nueva preparación explícita. Pruebe capas y SCALE sobre el firmware real, por cada transporte utilizado. Las pruebas de simulador no sustituyen estas comprobaciones ni certifican un tratamiento térmico.

Referencias: [manual oficial VX600](https://oss.novastar.tech/uploads/2025/06/VX600-All-in-One-Controller-User-Manual-V1.5.0-1.pdf), [protocolo NovaStar V1.1, §3.4.2 y apéndice V](https://www.ezledvisual.com/storage/file/20240926/1727345641282825.pdf). Prioridad0 está abajo y2 arriba; SCALE selecciona la menor prioridad activa única.
