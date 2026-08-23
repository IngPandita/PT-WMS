# Uso de asistencia de IA

## Herramienta

**Claude Code** (Claude Opus) ejecutándose dentro de VS Code, sobre el repositorio, con
acceso al sistema de archivos, a la terminal y a Docker. Toda la sesión quedó registrada en
el historial de la herramienta, que se entrega junto con este documento.

No se usaron Cursor, Copilot, ni Windsurf.

---

## Cómo se trabajó

No fue «pedir código y pegarlo». La sesión se organizó en tres fases que se repitieron por
cada bloque de trabajo:

1. **Diseño y auditoría.** Antes de escribir nada se acordó el modelo relacional y el
   protocolo de operación. El diseño pasó por tres rondas de auditoría adversarial —el
   objetivo explícito era *refutar* cada decisión, no confirmarla— que produjeron 23, 24 y
   20 hallazgos en bruto. Los que sobrevivieron a la refutación cambiaron el diseño; los
   demás quedaron registrados como descartados y por qué.
2. **Implementación.** Migraciones, backend, frontend y arneses de prueba.
3. **Verificación explícita.** Nada se dio por hecho porque compilara. Cada afirmación de
   este repositorio está respaldada por una suite que se ejecutó y cuyo resultado se
   reporta con su número.

---

## Qué se delegó

- Redacción de las migraciones PL/pgSQL: triggers, funciones, vistas e índices.
- Los *slices* verticales de .NET (comando, validador, manejador) siguiendo el patrón ya
  acordado.
- Los componentes de React y su cableado con TanStack Query.
- Los arneses de prueba: SQL de humo, verificación extremo a extremo con `curl`, xUnit,
  Vitest y Playwright.
- La documentación: la especificación de diseño y este repositorio.

## Qué NO se delegó

Las decisiones de producto y de modelo fueron humanas, y en varios casos corrigieron a la
herramienta:

- **El formato del SKU** (`[CATEGORÍA]-[CONSECUTIVO]`, p. ej. `ELEC-0001`).
- **La convención de nombres** `cat_` / `tbl_` / `rel_`, con la instrucción explícita de
  clasificar cada tabla y **señalar los casos ambiguos en vez de inventar un cuarto
  prefijo**. De ahí salió, por ejemplo, que `tbl_operaciones` no es un catálogo aunque se
  lea poco.
- **La regla de que ningún identificador estructural lleve información comercial**, que es
  la razón de que el código de cliente sea opaco y el nombre sí se pueda editar.
- **Que la protección contra doble ejecución no dependa del *debounce* ni de cancelar la
  petición.** Esta corrección cambió el diseño de raíz (ver abajo).
- **Que el alta en catálogos sea del usuario 1**, validada en backend y no ocultando un
  botón, y con la instrucción de revisar si existían endpoints genéricos que permitieran
  saltarse la regla.
- **Que las inconsistencias importantes se documenten antes de cambiarlas**, en lugar de
  «arreglarlas» por simetría.

---

## Decisiones de diseño que salieron de esa discusión

**El SKU se acuña y se congela.** La primera propuesta lo derivaba de la categoría vigente
con una columna generada. Se descartó: recategorizar un producto le habría cambiado el SKU,
y un identificador que cambia deja de identificar. El prefijo y el consecutivo se copian al
crear el producto y una clave foránea impide borrar o renombrar la categoría que los acuñó.

**La idempotencia es por intención, no por petición.** La primera versión mandaba una
`X-Idempotency-Key` acuñada en cada envío. Eso deja la garantía en manos del cliente: si el
frontend acuña una llave nueva al reintentar, el backend no tiene forma de saber que era el
mismo movimiento. Se rediseñó alrededor de un `id_operacion` acuñado **al formar la
intención** —al abrir el modal, no al pulsar— con dos barreras: la tabla de operaciones y un
índice único sobre la bitácora escrito por un trigger dentro de la misma transacción que
mueve la existencia. Si el índice salta, la existencia se revierte con él.

**«Desactivar» un movimiento no muta la bitácora.** Asienta el movimiento contrario, como
una póliza de reversa. La consecuencia interesante: revertir una entrada de +10 de la que ya
se consumieron 3 se **rechaza**, porque dejaría la existencia en −3. El ejemplo lo puso el
propio enunciado y el sistema, correctamente, lo niega.

**La asimetría entre alta y baja de catálogos se documentó, no se igualó.** Dar de alta
exige ser el operador 1; dar de baja sólo exige estar identificado. Igualarlas sería un
cambio de política, no una corrección, y nadie lo pidió. Queda escrito en la especificación
(§3.11) con el cambio exacto por si se decide lo contrario.

---

## Problemas encontrados y cómo se corrigieron

La mayoría los introdujo la herramienta y los cazó la verificación. Se listan porque son la
parte útil de este documento.

**Un interbloqueo (40P01) en el caso nominal del doble clic.** El protocolo de «supersesión»
que la herramienta propuso tomaba un candado de clave foránea *dentro* de la transacción de
trabajo, invirtiendo el orden de bloqueo. Lo encontraron tres auditorías independientes con
lentes distintas. No se parcheó: se eliminó la supersesión y se sustituyó por idempotencia
por intención, que no necesita ese candado.

**Migraciones corrompidas por el propio parcheo automático.** Tres funciones quedaron con
`as \` en vez de `as $$` porque en JavaScript `$$` dentro de un `String.replace` es una
secuencia de escape. Peor: al revisar con `cat -A`, que dibuja el fin de línea como `$`, el
hallazgo correcto estuvo a punto de descartarse por parecer un falso positivo. Se corrigió y
se cambió el método de parcheo por uno basado en posiciones, no en sustitución de texto.

**La importación era la vía de escape de la regla de catálogos.** Restringir el alta en el
endpoint no bastaba: la importación masiva crea productos, y un producto es un registro de
catálogo. Por eso la restricción acabó en un trigger de la base aplicado a **todas** las
tablas `cat_%` —con una comprobación de cobertura que hace fallar la migración si alguna
quedara sin él—, y la importación marca esos renglones con `PERMISO_ALTA_CATALOGO` en vez de
tumbar el lote entero.

**Una escalada de privilegios por la puerta de atrás.** Al implementar la edición de
catálogos se detectó que el permiso de exportación se decide por el **rol** del operador. Si
la edición dejaba tocar `cat_usuarios.rol`, cualquier operador podía ascenderse a SUPERVISOR
y concederse la exportación —que incluye precios y valuación—. El rol quedó reservado al
operador 1, exigido en el motor (`WM021`).

**Una reserva que podía quedar bloqueada para siempre.** En el ejecutor idempotente, abrir la
conexión de trabajo estaba *fuera* del `try`. Si el cliente cortaba justo ahí, la operación
ya estaba reservada como `EN_PROCESO` y nadie la cerraba: todo reintento con el mismo
identificador recibía `WM013` indefinidamente. Lo delató una prueba de reintento tras
*timeout* que empezó a fallar. Se movió la apertura dentro del `try` y, además, se hospedó
en la API el barrido que la migración `0003` daba por programado «externamente» y que en la
práctica no ejecutaba nadie.

**Un tope silencioso de 1000 renglones** en el detalle de una importación, y otro de 200 que
el código anunciaba como 500. Los dos se corrigieron: el primero ahora va paginado, el
segundo dice la verdad y su consecuencia está escrita.

**Errores de orden en las respuestas.** Un operador sin permiso con datos mal escritos
recibía `400` en vez de `403`, porque la validación corría antes que la comprobación de
permiso. Se invirtió: primero se responde «no puedes», no «te falta un campo».

**Fallos del arnés, no del producto.** Varios: `grep -c` cuenta líneas y no coincidencias;
el `curl` de Windows no resuelve rutas POSIX; una prueba de rol usaba un operador que la
semilla ya creaba como SUPERVISOR, de modo que «ascenderlo» no cambiaba nada y el trigger no
tenía por qué dispararse; y el sondeo `pg_isready` preguntaba por el socket unix, que el
servidor **temporal** de `initdb` también atiende —de ahí un «listo» falso que estrellaba las
migraciones de forma intermitente—. Se corrigieron todos; el último, preguntando por TCP.

---

## Cómo se validó el resultado

Todo corre contra PostgreSQL 16 y .NET 8 reales, en contenedores desechables. No hay dobles
ni motores en memoria.

| Suite | Qué cubre | Resultado |
|---|---|---|
| `db/pruebas/verificar.sh` | Esquema, triggers, inmutabilidad, concurrencia con sesiones paralelas | 5 suites, **58 aserciones**, 0 fallos |
| `dotnet test` | Análisis de SKU, huella de intención, mapeo de errores, validadores, paginación | **83 pruebas**, 0 fallos |
| `tests/verificar_api.sh` | La API sobre HTTP: reintento tras *timeout*, latencia, cancelación a media transacción, permisos | **279 aserciones**, 0 fallos |
| `web` · Vitest | Componentes: idempotencia del modal, búsqueda con carreras, paginación, permisos | **47 pruebas**, 0 fallos |
| `web` · Playwright | Navegador: ciclo completo, importación, doble clic bajo latencia, dos operadores concurrentes | **10 escenarios**, 0 fallos |

Dos criterios se aplicaron sin excepción:

- **No declarar terminado nada por el hecho de que compile.** Cada afirmación se comprobó
  ejecutando la suite correspondiente y reportando su número.
- **Provocar el fallo antes de creerse la garantía.** Las pruebas de concurrencia abren 25
  sesiones simultáneas contra la misma fila; las de idempotencia envían la misma operación
  10 veces en paralelo sobre HTTP; las de navegador abren dos pestañas con operadores
  distintos sobre el mismo producto. Una garantía que sólo se ha visto funcionar en el caso
  feliz no está verificada.
