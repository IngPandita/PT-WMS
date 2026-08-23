# 008 · Edición de catálogos, pruebas E2E y documentación

**Periodo:** 2026-08-23 00:44:53 UTC → 2026-08-23 02:07:03 UTC

**Intervenciones en este archivo:** 1 del usuario, 12 de Claude, 0 del sistema.

---

### [USUARIO] · 2026-08-23 00:44:53 UTC

Continua con los pendientes

---

‹ 12 operaciones de herramienta: Bash×11, Write×1 ›

### [CLAUDE] · 2026-08-23 00:47:40 UTC

Ahora la lógica de aplicación para editar y cambiar vigencia.

---

‹ 4 operaciones de herramienta: Bash×3, Write×1 ›

### [CLAUDE] · 2026-08-23 00:49:36 UTC

Ahora el slice de edición y cambio de vigencia.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-23 00:50:54 UTC

Ahora corrijo el tipado de la vigencia para que Npgsql no reciba un parámetro sin tipo.

---

‹ 3 operaciones de herramienta: Bash×3 ›

### [CLAUDE] · 2026-08-23 00:51:31 UTC

Ahora las rutas HTTP.

---

‹ 19 operaciones de herramienta: Bash×16, Write×3 ›

### [CLAUDE] · 2026-08-23 00:59:14 UTC

Ahora la página de catálogos con selección y acciones.

---

‹ 26 operaciones de herramienta: Bash×22, Write×4 ›

### [CLAUDE] · 2026-08-23 01:16:36 UTC

Ahora corrijo la prueba del rol (el usuario 2 de la semilla ya es SUPERVISOR) y vuelvo a correr.

---

‹ 20 operaciones de herramienta: Bash×18, Write×2 ›

### [CLAUDE] · 2026-08-23 01:28:27 UTC

Ahora escribo la configuración y las pruebas de Playwright.

---

‹ 4 operaciones de herramienta: Write×3, Bash×1 ›

### [CLAUDE] · 2026-08-23 01:29:18 UTC

Ahora escribo los cuatro escenarios E2E.

---

‹ 4 operaciones de herramienta: Write×2, Bash×2 ›

### [CLAUDE] · 2026-08-23 01:31:09 UTC

Ahora los tres escenarios restantes.

---

‹ 9 operaciones de herramienta: Bash×5, Write×4 ›

### [CLAUDE] · 2026-08-23 01:33:57 UTC

Ahora reconstruyo la pila y ejecuto Playwright.

---

‹ 12 operaciones de herramienta: Bash×11, Write×1 ›

### [CLAUDE] · 2026-08-23 01:45:53 UTC

Ahora actualizo E3 y E4b para usar la clave exacta, y E1 para no confundir `<option>` de `<select>` con la lista del buscador.

---

‹ 24 operaciones de herramienta: Bash×19, Write×5 ›

### [CLAUDE] · 2026-08-23 02:07:03 UTC

Los tres pendientes quedaron cerrados. Esto es lo que se hizo.

## 1 · Editar y dar de baja catálogos desde la interfaz

Implementé la política que **el motor ya imponía**, no una nueva por simetría: corregir y dar de baja exigen un operador identificado, cualquiera; sólo el alta exige ser el usuario 1. Es la asimetría que documenté la vez pasada, y sigue documentada — no la cambié por mi cuenta.

Lo que sí endurecí, porque la revisión encontró un agujero real:

**El rol de un operador era una escalada de privilegios.** `PermisoExportacion` autoriza la exportación **por rol**. Si la edición dejaba escribir `cat_usuarios.rol`, cualquier OPERADOR podía ascenderse a SUPERVISOR y concederse la exportación —que incluye precios y valuación— sin pasar por nadie. El rol quedó reservado al operador 1, exigido en el motor con `WM021`. El rol del propio operador 1 es fijo incluso para él.

**El operador SISTEMA no se puede desactivar** (`WM022`): es el único que puede dar de alta en catálogos y `fn_ajustar_existencia` rechaza operadores inactivos, así que darlo de baja dejaba el sistema sin forma de deshacerlo desde la aplicación.

**Concurrencia optimista en los cinco catálogos.** Productos y órdenes ya tenían `version_concurrencia`; usuarios, categorías, almacenes y clientes sólo `actualizado_en` — dos operadores corrigiendo el mismo cliente producían «el último gana» en silencio. La migración `0007` lo uniforma, y la versión es obligatoria en el `PUT`: una obsoleta devuelve 409/`WM008` en vez de pisar. Cero filas actualizadas se diagnostica antes de responder, porque «no existe» (404) y «alguien más lo modificó» (409) no dan el mismo consejo.

La baja no borra: sella quién y cuándo, y reactivar conserva ese sello. Pedir una vigencia que el registro ya tiene devuelve `WM023` en vez de fingir que hizo algo.

## 2 · Playwright

10 escenarios contra la pila real (`docker compose up`), no contra mocks: E1 el ciclo completo (catálogo → producto → orden → confirmar → enviar → bitácora → tablero), E2 importación con errores y reimportación que no duplica, E3 el modal bajo latencia y el stepper, E4 dos pestañas con operadores distintos, E5 los permisos de catálogo incluida una llamada directa al endpoint saltándose la interfaz.

En E3 no fuerzo clics sobre un botón deshabilitado: un clic forzado cae en el fondo del modal y lo cierra, y la prueba acabaría midiendo el arnés. El reenvío con la petición en vuelo está cubierto sobre HTTP, que es donde se puede provocar sin ambigüedad; lo dejé escrito en el propio archivo.

## 3 · README.md y AI-USAGE.md

El README lleva instrucciones de arranque, recorrido de uso, las tres cosas que conviene saber antes de leer el código, y los comandos de las cinco suites. `AI-USAGE.md` cubre lo que pide el enunciado, incluida la lista de errores que **la herramienta introdujo y la verificación cazó** — que es la parte útil de ese documento.

## Dos defectos reales que aparecieron de camino

**Una reserva podía quedar bloqueada para siempre.** En el ejecutor idempotente, abrir la conexión de trabajo estaba *fuera* del `try`. Si el cliente cortaba justo ahí, la operación ya estaba reservada como `EN_PROCESO` y nadie la cerraba: todo reintento con el mismo id recibía `WM013` indefinidamente. Lo delató la prueba de reintento tras *timeout*, que empezó a fallar. Además hospedé en la API el barrido que la migración `0003` daba por programado «externamente» — `pg_cron` no existe en `postgres:16-alpine`, así que ese *externamente* no era nadie.

**Vitest estaba corriendo los specs de Playwright** y reportando 5 archivos fallidos. Acoté `include` a `src/`.

## Verificación ejecutada, ya con todo integrado

| Suite | Resultado |
|---|---|
| `db/pruebas/verificar.sh` | 5 suites, **58 aserciones**, 0 fallos |
| `dotnet test` | **83 pruebas**, 0 fallos |
| `tests/verificar_api.sh` | **279 aserciones**, 0 fallos |
| `npm test` (Vitest) | 5 archivos, **47 pruebas**, 0 fallos |
| `npm run e2e` (Playwright) | **10 escenarios**, 0 fallos |
| `docker compose up --build` desde volumen vacío | 7 migraciones aplicadas, api 200, web 200 |

Archivos nuevos: [0007_edicion_catalogos.sql](db/migraciones/0007_edicion_catalogos.sql), [humo_catalogos.sql](db/pruebas/humo_catalogos.sql), [EditarCatalogo.cs](src/Wms.Application/Catalogos/EditarCatalogo.cs), [BarridoOperaciones.cs](src/Wms.Api/Servicios/BarridoOperaciones.cs), [ModalCatalogo.tsx](web/src/componentes/ModalCatalogo.tsx), los cinco specs en [web/e2e/](web/e2e/), [README.md](README.md) y [AI-USAGE.md](AI-USAGE.md).

Queda un detalle que no toqué y conviene decidir: **el nombre de un producto y el de un cliente son editables, y la bitácora los resuelve por identificador** — así que corregir un nombre reescribe cómo se lee un movimiento antiguo. Es correcto para una corrección de captura, discutible para un cambio de razón social. Si quiere que la bitácora conserve el nombre vigente al momento del movimiento, eso es una columna congelada más, no una condición.

---
