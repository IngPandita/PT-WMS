# Mini WMS + Órdenes — Especificación de diseño

| | |
|---|---|
| **Fecha** | 2026-08-21 |
| **Autor** | pedro_zc.32@hotmail.com, asistido por Claude Code (protocolo multi-agente) |
| **Estado** | Fase 1 cerrada — modelo de datos y arquitectura. Pendiente de aprobación para Fase 2 (codificación). |
| **Base** | `Prueba Técnica - Mini WMS + Órdenes.md` |
| **Stack** | .NET 8 Web API (C#) · React 18 + TypeScript + Vite + Tailwind + shadcn/ui · PostgreSQL 15+ (Supabase) |

> **Alcance declarado:** sin autenticación de usuarios y sin RLS. El foco es consistencia de
> catálogos, integridad relacional, control de inventario y mitigación de concurrencia.
>
> **Estado de verificación:** ✅ **Capa de datos ejecutada y verificada.** `db/pruebas/verificar.sh`
> aplica las tres migraciones sobre un PostgreSQL 16 limpio
> (`psql -v ON_ERROR_STOP=1 --single-transaction`), carga la semilla y corre tres suites —
> idempotencia, ciclo de órdenes y **concurrencia real con sesiones paralelas** — con
> **37 aserciones y 0 fallos**. Tres rondas de auditoría estática multi-agente precedieron a la
> ejecución; la tercera detectó que el archivo **no compilaba**, algo que ninguna revisión estática
> anterior había visto.
>
> **Capa HTTP verificada.** `tests/verificar_api.sh` levanta Postgres + migraciones + semilla + la
> API .NET 8 en contenedores y ejerce los endpoints con `curl`: **80 aserciones, 0 fallos**. Cubre
> el escenario literal del requerimiento (modal, conexión lenta, segundo clic → `+2` y **un solo**
> movimiento), el **reintento tras timeout real** del cliente, el motivo editado entre reenvíos, 10
> envíos simultáneos del mismo `id_operacion`, el aislamiento por operador, y el **ciclo completo de
> órdenes**: alta idempotente, transición inválida, reserva sin tocar existencia física, reenvío de
> la confirmación sin doble reserva, embarque, `ENVIADA` terminal, cancelación con liberación, y
> atribución independiente de quién creó y quién canceló. Más **36 pruebas unitarias**.
>
> **Importación verificada** (111 aserciones E2E en total): plantilla descargable, mezcla de
> renglones válidos e inválidos con sus códigos estables, **reimportar el mismo archivo reanuda el
> lote y no duplica existencias**, modo `ALTA_O_ACTUALIZA`, archivo 100 % inválido que nunca abre
> transacción de trabajo, y resultado consultable después.
>
> **Frontend verificado**: compila (`tsc -b && vite build`) y **9 pruebas de componente** fijan la
> disciplina del `id_operacion` en el stepper — el botón nunca se deshabilita, la intención se
> acumula, un refetch no descarta lo pendiente, y **tras un fallo el reintento conserva el mismo
> id**.
>
> **`docker compose up` verificado de extremo a extremo**, incluida la segunda corrida: el
> migrador lleva registro de lo aplicado, así que es re-ejecutable. El reenvío del mismo
> `id_operacion` atravesando nginx → API → Postgres devuelve `fueReenvio: true` sin volver a sumar.
>
> **Sin verificar todavía:** escenarios E2E de navegador (Playwright) y la vista de captura de
> productos y catálogos desde la interfaz (hoy son de solo lectura).

---

# 1. Esquema de la base de datos

## 1.1 Convenciones

### Prefijos de tabla

| Prefijo | Significado | Discriminador aplicado |
|---|---|---|
| `cat_` | Catálogo / información de referencia relativamente estática | Se lee mucho, se escribe poco, su borrado está restringido por definición |
| `tbl_` | Data operativa o transaccional | La fila **sobrevive** a las transacciones que la tocan, tiene estado propio, otras entidades se le restringen (`RESTRICT`) |
| `rel_` | Relación entre entidades | La fila **no tiene ciclo de vida propio**: existe solo como componente de una entidad padre y muere con ella (`CASCADE`) |

El discriminador es **la dependencia de ciclo de vida**, no la forma de la llave. Sin un criterio
explícito la clasificación sería ad-hoc y dos personas llegarían a resultados distintos.

### Identificadores

| Elemento | Regla | Ejemplo |
|---|---|---|
| Esquema | `wms` (no `public`) | `wms.cat_productos` |
| Tabla | `<prefijo>_<sustantivo>` minúsculas, snake_case, español | `tbl_movimientos_inventario` |
| Columna | snake_case español; núcleo antes que calificador | `cantidad_reservada`, `tipo_movimiento` |
| Timestamp | sufijo `_en` — **toda** columna terminada en `_en` es `timestamptz` | `creado_en`, `confirmado_en` |
| Booleano | prefijo `es_` | `es_activo`, `es_existencia_baja` |
| Llave primaria | `pk_<tabla>` | `pk_tbl_inventario` |
| Llave foránea | `fk_<tabla>__<tabla_referenciada>` | `fk_tbl_ordenes__cat_clientes` |
| Unicidad | `uq_<tabla>__<sufijo>` | `uq_cat_productos__acunacion` |
| Verificación | `ck_<tabla>__<sufijo>` | `ck_tbl_inventario__cobertura_reserva` |
| Índice | `ix_<tabla>__<sufijo>` / `ux_` si es único | `ix_tbl_ordenes__estatus_fecha` |
| Trigger | `trg_<tabla>__<acción>` | `trg_tbl_inventario__bitacora` |
| Función | `fn_<verbo>_<objeto>` | `fn_ajustar_existencia` |
| Vista | `vw_<tema>` | `vw_tablero_inventario` |
| Secuencia | `seq_<tabla>` | `seq_tbl_ordenes` |

**Excepciones léxicas aceptadas** (términos de dominio no traducibles, declaradas en la cabecera
del DDL): `sku`, `hash`, `jsonb`.

**Por qué esquema `wms` y no `public`.** No es cosmético. En Supabase, PostgREST expone
automáticamente el esquema `public`. Como esta prueba no lleva RLS, publicar el modelo en `public`
dejaría un API REST anónimo con escritura directa sobre inventario, saltándose las reglas de
negocio, la máquina de estados y la idempotencia del backend. Con esquema propio y `revoke` sobre
`anon`/`authenticated`, **la única puerta al inventario es la API de .NET 8**.

## 1.2 Inventario de tablas

| # | Tabla | Prefijo | Propósito | Llave primaria |
|---|---|---|---|---|
| 0 | `cat_usuarios` | `cat_` | Registro de operadores (sin credenciales) para atribuir cada movimiento | `id` |
| 1 | `cat_categorias` | `cat_` | Catálogo de categorías + contador de acuñación de SKU | `id` |
| 2 | `cat_almacenes` | `cat_` | Catálogo de almacenes con código de longitud fija | `id` |
| 3 | `cat_reglas_sku` | `cat_` | Reglas Regex dinámicas del SKU (una activa) | `id` |
| 4 | `cat_clientes` | `cat_` | Catálogo de clientes con código opaco consecutivo | `id` |
| 5 | `cat_productos` | `cat_` | Catálogo de productos con SKU acuñado e inmutable | `id` |
| 6 | `tbl_inventario` | `tbl_` | Existencias por producto y almacén | **`(producto_id, almacen_id)`** |
| 7 | `tbl_ordenes` | `tbl_` | Órdenes de venta con máquina de estados | `id` |
| 8 | `rel_orden_producto` | `rel_` | Partidas de la orden, con precio congelado | `id` (+ `uq (orden_id, producto_id)`) |
| 9 | `tbl_movimientos_inventario` | `tbl_` | Bitácora append-only de doble cubeta | `id` |
| 10 | `tbl_lotes_importacion` | `tbl_` | Lotes de carga masiva | `id` |
| 11 | `tbl_renglones_importacion` | `tbl_` | Resultado por renglón importado | `id` (+ `uq (lote_id, numero_renglon)`) |
| 12 | `tbl_operaciones` | `tbl_` | Registro de operaciones: primera barrera de idempotencia | `id_operacion` |

**Vistas:** `vw_tablero_inventario`, `vw_ordenes_detalle`, `vw_orden_partidas`,
`vw_movimientos_detalle`, `vw_importacion_resultado`, `vw_indicadores_operacion`,
`vw_indicadores_almacen`, `vw_serie_movimientos_diaria`, `vw_aportacion_por_usuario`.

## 1.3 Mapa de relaciones

```text
cat_usuarios ──── id ───┬──────► tbl_movimientos_inventario.usuario_id      (RESTRICT)
                        ├──────► tbl_ordenes.{creado,confirmado,enviado,cancelado}_por_usuario_id (RESTRICT)
                        ├──────► tbl_lotes_importacion.creado_por_usuario_id(RESTRICT)
                        ├──────► tbl_operaciones.usuario_id                 (RESTRICT)
                        └──────► <catálogo>.desactivado_por_usuario_id      (RESTRICT)

tbl_operaciones ── id_operacion ─╌╌► tbl_movimientos_inventario.id_operacion
                                     (SIN FK: la bitácora es permanente y las
                                      operaciones se purgan a las 48 h. La
                                      unicidad que importa es el índice único
                                      del propio movimiento, que no depende
                                      de esa tabla.)

cat_categorias ──┬── id ────────► cat_productos.categoria_id      (RESTRICT / UPDATE CASCADE)
                 └── codigo ────► cat_productos.sku_prefijo       (RESTRICT / UPDATE RESTRICT)

cat_productos ─── id ───┬──────► tbl_inventario.producto_id       (RESTRICT)
                        ├──────► rel_orden_producto.producto_id   (RESTRICT)
                        └──────► tbl_renglones_importacion.producto_id (RESTRICT)

cat_almacenes ─── id ───┬──────► tbl_inventario.almacen_id        (RESTRICT)
                        ├──────► tbl_ordenes.almacen_id           (RESTRICT)
                        └──────► tbl_renglones_importacion.almacen_id (RESTRICT)

cat_clientes ──── id ──────────► tbl_ordenes.cliente_id           (RESTRICT)

tbl_inventario ── (producto_id, almacen_id) ─► tbl_movimientos_inventario  (RESTRICT, FK COMPUESTA)

tbl_ordenes ───── id ───┬──────► rel_orden_producto.orden_id      (CASCADE)
                        └──────► tbl_movimientos_inventario.orden_id (RESTRICT, nullable)

tbl_lotes_importacion ── id ─┬─► tbl_renglones_importacion.lote_id (CASCADE)
                             └─► tbl_movimientos_inventario.lote_importacion_id (RESTRICT, nullable)
```

**Política de borrado y soft-delete.** Ninguna entidad transaccional se borra jamás. `RESTRICT` en
toda relación que atraviese la historia; `CASCADE` únicamente donde la fila hija carece de sentido
sin su padre (partidas de una orden, renglones de un lote). **Ninguna FK que atraviese información
histórica es `SET NULL`** — la de `tbl_renglones_importacion.producto_id` lo era y se corrigió a
`RESTRICT`: perder a qué producto se aplicó un renglón rompería la reconstrucción histórica.

La baja de catálogos es lógica y **auditada**: los cinco catálogos desactivables
(`cat_usuarios`, `cat_categorias`, `cat_almacenes`, `cat_clientes`, `cat_productos`) llevan
`desactivado_en` y `desactivado_por_usuario_id`, sellados automáticamente por
`fn_sellar_baja_logica` y forzados por un `CHECK` que ata la vigencia a la fecha de baja. Como
todas las FK históricas son `RESTRICT`, un registro desactivado **siempre sigue siendo resoluble**
desde cualquier movimiento pasado: la historia nunca depende del estado actual del registro.

## 1.4 Piezas de ingeniería que sostienen el modelo

### Acuñación del SKU — `[CATEGORÍA]-[CONSECUTIVO]`, ancho fijo de 9

El SKU no se captura: **se acuña**. `sku_prefijo` y `sku_consecutivo` se congelan en el `INSERT`
y `sku` es una columna `GENERATED ALWAYS AS ... STORED` derivada de ambas, imposible de
desincronizar. Un trigger `BEFORE UPDATE` bloquea cualquier intento de reasignación.

`categoria_id` es **independiente y mutable**: reclasificar un producto está permitido y **no**
reescribe su SKU. Un producto creado en `ELEC` que pase a `HOGA` conservará `ELEC-0042` para
siempre, porque la etiqueta ya está impresa en la caja y el SKU ya está en órdenes cerradas.
La integridad del prefijo la garantiza una FK contra `cat_categorias(codigo)`: el prefijo siempre
corresponde a *alguna* categoría real, no necesariamente a la vigente.

La asignación del consecutivo es **autorreparable**: se calcula como
`greatest(contador, max(consecutivo real de la categoría)) + 1` dentro de un `UPDATE` que toma el
row lock de la categoría. Dos altas simultáneas se serializan y jamás obtienen el mismo folio;
y un contador que quedó atrás por un rollback, una semilla o un restore se recupera solo.

**Techo:** 9 999 productos por categoría. Ampliar a 5 dígitos es una migración de
`cat_reglas_sku` más la expresión de la columna generada.

### Control de concurrencia — cuatro mecanismos, cuatro problemas distintos

Confundirlos es el error clásico. Cada uno resuelve algo que los otros no:

| Mecanismo | Problema que resuelve | Dónde aplica |
|---|---|---|
| `UPDATE ... SET cantidad = cantidad + delta` en una sola sentencia | **Lost update**: el statement toma el row lock y re-evalúa la fila tras esperar | Siempre en el ajuste rápido |
| `version_concurrencia` (testigo opcional) | **Stale read**: la UI decide sobre un valor que ya venció | Formularios que escriben cantidades absolutas |
| `CHECK (cantidad_fisica >= 0)` y `(cantidad_reservada <= cantidad_fisica)` | **Sobreventa por cualquier ruta**, incluso un `UPDATE` manual | Red de seguridad del motor |
| `ORDER BY producto_id` en los bucles de orden | **Deadlock** entre órdenes concurrentes con productos comunes | Confirmar / enviar / cancelar |

**El ajuste rápido no exige `version_concurrencia`, y es deliberado.** Si dos operarios pulsan
`+1` a la vez, ambos clics son intención legítima y ambos deben aplicarse: el delta es conmutativo.
Rechazar el segundo con un 409 sería un defecto de producto disfrazado de rigor técnico.

### Bitácora automática de doble cubeta

Un trigger `AFTER INSERT OR UPDATE` sobre `tbl_inventario` escribe el movimiento. Esto garantiza
el invariante **"ninguna mutación de existencia queda sin registro"**, incluso ante un `UPDATE`
manual desde `psql`. La tabla es de solo inserción: un trigger `BEFORE UPDATE OR DELETE` aborta
cualquier mutación.

El trigger no sabe *por qué* cambió la existencia, así que el contexto (tipo, origen, orden, lote,
llave de idempotencia, motivo, actor) viaja en GUC locales de transacción que las funciones de
negocio fijan antes y **limpian después**. La limpieza no es opcional: sin ella, una segunda
escritura en la misma transacción heredaría el contexto de la primera y la bitácora registraría
un hecho falso e inmutable.

Se registran **dos cubetas** (`delta_fisica` y `delta_reservada`) porque confirmar una orden mueve
reserva sin mover físico, y embarcarla mueve ambas. Una bitácora de una sola columna no puede
representar eso sin mentir. Tres `CHECK` obligan a que la aritmética cuadre y a que el tipo de
movimiento concuerde con los deltas.

**Nunca se acumula un valor sin historial.** Si el usuario 1 suma 5 y el usuario 2 suma 3 sobre el
mismo producto, la existencia queda en `base + 8` **y quedan dos renglones independientes**:

| `uuid_movimiento` | `usuario_id` | `producto_sku` | `delta_fisica` | `fisica_antes` | `fisica_despues` | `creado_en` |
|---|---|---|---|---|---|---|
| `a3f1…` | USR-0001 | ELEC-0001 | `+5` | 10 | 15 | 14:02:11.331 |
| `b7c9…` | USR-0002 | ELEC-0001 | `+3` | 15 | 18 | 14:02:11.487 |

Cada renglón guarda producto, almacén, cantidad con estado antes y después, fecha, usuario
responsable, identificador público único, tipo de movimiento y su origen tipado. La vista
`vw_aportacion_por_usuario` agrega esa evidencia por operador.

**El estado del movimiento se deriva, no se almacena.** Un renglón mutable no es una bitácora:
almacenar un estado que alguien pueda cambiar destruiría la garantía que la hace confiable.
`vw_movimientos_detalle` expone `estado` como columna calculada — `APLICADO`, `CONSUMIDO` (una
reserva que ya se embarcó) o `COMPENSADO` (una reserva liberada por cancelación) — derivada del
ciclo de vida de la orden. La información es la misma y no admite manipulación.

### Atribución obligatoria: `cat_usuarios`

El alcance excluye autenticación, pero la trazabilidad exige saber **quién** ejecutó cada
movimiento. `cat_usuarios` es un registro de operadores sin credenciales: el frontend selecciona
el operador activo, la API lo propaga en `X-Usuario-Id` y el trigger de bitácora lo graba.

La atribución no es opcional: `fn_fijar_contexto_movimiento` **aborta con `WM014`** si el usuario
no se declara, no existe o está inactivo, y el trigger de bitácora vuelve a verificarlo. Ninguna
mutación de existencia puede ser anónima, ni siquiera un `UPDATE` manual desde `psql`.

### Idempotencia por operación — la garantía central del sistema

> **Una operación del usuario = un solo movimiento aplicado.**
> Un reenvío de la misma operación es seguro y no vuelve a aplicar nada.
> Dos operaciones legítimas de usuarios distintos se contabilizan ambas.

**`id_operacion` identifica una intención, no una petición HTTP.** El cliente lo acuña **una sola
vez**, cuando el usuario forma la intención — al abrir el modal, al empezar a ajustar la cantidad —
y lo reutiliza en **todos** los reenvíos de esa misma intención: reintento por timeout, segundo
clic sobre el botón de confirmar, reintento del navegador o de un proxy. Se invalida solo cuando la
operación se aplica con éxito, o cuando el usuario cambia la intención.

Esa es la corrección de un defecto de diseño real: la versión anterior acuñaba una llave **por
petición**, de modo que un segundo clic sobre el mismo modal producía una llave distinta y el
backend lo trataba como una operación nueva. La idempotencia existía, pero una decisión del cliente
la volvía inútil justo en el escenario que debía cubrir.

#### Las dos barreras

| # | Barrera | Qué garantiza | Dónde vive |
|---|---|---|---|
| 1 | `pk_tbl_operaciones` (`id_operacion`) | Un reenvío no vuelve a ejecutar la lógica; se devuelve la respuesta original | `INSERT … ON CONFLICT DO NOTHING` en fase 0 |
| 2 | **`ux_tbl_movimientos_inventario__operacion`** `(id_operacion, producto_id, almacen_id, tipo_movimiento)` | Un movimiento de esa operación **no puede existir dos veces**, pase lo que pase | Índice único del motor |

La segunda barrera es la que hace la garantía **ineludible**, y merece explicarse: el trigger
`trg_tbl_inventario__bitacora` escribe la bitácora **dentro de la misma transacción** que muta
`tbl_inventario`. Si un segundo intento de la misma operación llegara a ejecutarse — por un bug de
la aplicación, por dos peticiones que atraviesan la fase 0 a la vez, o por `SQL` manual — el
`INSERT` de su movimiento viola el índice único, el trigger aborta con `23505` y **la mutación de
existencia se revierte con él**. No hay ruta por la que el mismo `id_operacion` sume dos veces.

Por eso `tbl_movimientos_inventario.id_operacion` es `NOT NULL`: un movimiento sin operación sería
un movimiento fuera del control de idempotencia. El trigger lo verifica y aborta con `WM012` si el
contexto no lo trae.

Es también a nivel de **renglón** y no de operación, porque una operación produce N movimientos:
confirmar una orden de tres partidas escribe tres renglones con el mismo `id_operacion` y distinto
producto. La unicidad de la operación completa vive en `pk_tbl_operaciones`.

#### El `id_operacion` lleva el operador como prefijo

Formato: `<usuario_id>:<identificador acuñado por el cliente>`, con `ck_tbl_operaciones__formato` y
`ck_tbl_operaciones__prefijo_actor` obligándolo. Sin ese espacio de nombres, dos operadores que
acuñaran el mismo identificador con cuerpos idénticos producirían el mismo hash, y el segundo
recibiría `200` con la respuesta del primero: **su movimiento desaparecería sin error**. El
prefijo convierte la convención del cliente en un invariante del motor.

Consecuencia para el frontend: cambiar el operador activo **invalida toda intención en vuelo**,
igual que cambiar la cantidad.

#### Qué entra en `hash_peticion` — definición normativa

El hash es SHA-256 del JSON canónico de **exactamente los campos de la intención**, y su conjunto
debe ser **superconjunto de las columnas de `ux_…__operacion` y nada más**:

| Ruta | Campos del hash |
|---|---|
| `/api/inventario/ajustar` | `{almacen_id, delta, producto_id, tipo_movimiento, usuario_id}` |
| `/api/ordenes/{id}/{acción}` | `{accion, orden_id, usuario_id}` |
| `/api/importacion` | `{hash_archivo, modo, usuario_id}` |

**Excluidos siempre:** `motivo`, `version_esperada`, marcas de tiempo y nonces. Incluir un campo
editable haría que reenviar la misma intención con el motivo corregido produjera `WM015`
permanente — y el usuario, al no poder avanzar, cerraría el modal y acuñaría un id nuevo, que sí
se aplicaría por segunda vez. Es decir: un hash demasiado amplio **causa** la doble aplicación que
pretende evitar. Campos ausentes, `null` y `""` se normalizan al mismo valor.

Se comparan además **`alcance` y `ruta`**. Comparar solo el hash es el espejo exacto de la doble
aplicación: `POST /ordenes/12/confirmar` y `POST /ordenes/12/enviar` tienen ambos cuerpo vacío
—el id va en la ruta—, así que con el mismo `id_operacion` el envío recibiría `200` con la
respuesta de la confirmación, `fn_enviar_orden` no se invocaría nunca y **no habría embarque ni
descuento de existencia ni error alguno**.

**Tras un `WM015` está prohibido re-acuñar el id.** La única acción segura es consultar
`GET /api/inventario/movimientos?id_operacion=<id>` para saber si la intención ya se materializó.

#### Veredictos de la reserva (fase 0)

`fn_reservar_operacion` devuelve un veredicto en vez de lanzar excepciones, para que .NET decida el
HTTP sin interpretar mensajes:

| Veredicto | Situación | Respuesta |
|---|---|---|
| `NUEVA` | Primera vez, o reintento de una que falló sin aplicar nada | Se ejecuta |
| `EN_CURSO` | Otro reenvío la está ejecutando ahora mismo | `409` + `Retry-After` |
| `YA_COMPLETADA` | Ya se aplicó | `200` con la **respuesta original almacenada**; no se genera movimiento |
| `CARGA_DISTINTA` | Mismo `id_operacion` con otro cuerpo, alcance o ruta: error del cliente, no un reintento | `409` / `WM015` |
| `CONFLICTO_DE_ACTOR` | El prefijo del id no corresponde al operador que lo envía | `409` / `WM016`; **nunca** se devuelve `cuerpo_respuesta` en esta rama |

Dos reenvíos **simultáneos** no se escapan: el `ON CONFLICT` del segundo espera sobre la inserción
especulativa del primero y, al desbloquearse, observa un estado ya definido — nunca uno intermedio.

Una operación que falla se marca `FALLIDO`, no `COMPLETADO`, y por tanto **sigue siendo
reejecutable con el mismo `id_operacion`**: no aplicó nada, así que reintentarla es correcto. Es la
distinción que hace segura la combinación de reintentos y idempotencia.

#### La cancelación no es una garantía

Cancelar una petición desde el frontend es **UX y ahorro de tráfico**, nunca integridad. Si la
petición ya llegó y su transacción ya confirmó, abortar el socket no revierte nada — PostgreSQL no
aborta un `COMMIT` en curso. El sistema no finge lo contrario: la protección contra duplicados vive
en las dos barreras anteriores, que no dependen de ninguna ventana de tiempo, de ningún `debounce`
y de ninguna velocidad de conexión.

### Catálogo de errores de negocio

Diez `RAISE` compartiendo `errcode = 23514` obligarían a .NET a hacer string-matching sobre
mensajes en español. El sistema define una **clase SQLSTATE propia `WM`**, legible por máquina:

| Código | Significado | HTTP | ¿Polly reintenta? |
|---|---|---|---|
| `WM001` | Transición de orden inválida | 409 | No |
| `WM002` | Existencia insuficiente | 422 | No |
| `WM003` | SKU inmutable | 409 | No |
| `WM004` | SKU duplicado | 409 | No |
| `WM005` | Sin inventario en el almacén | 422 | No |
| `WM006` | Bitácora inmutable | 409 | No |
| `WM007` | Orden no editable | 409 | No |
| `WM008` | Conflicto de concurrencia optimista | 409 | **No** — reenviar la misma versión vuelve a fallar |
| `WM009` | Formato de SKU inválido | 422 | No |
| `WM010` | `monto_total` es derivado | 409 | No |
| `WM011` | Orden sin partidas | 422 | No |
| `WM012` | Argumento inválido (delta cero, `id_operacion` ausente) | 400 | No |
| `WM013` | Operación duplicada en curso | 409 + `Retry-After` | No |
| `WM014` | Usuario inactivo o no declarado | 422 | No |
| `WM015` | Mismo `id_operacion` con carga, alcance o ruta distintos | 409 | No |
| `WM016` | `id_operacion` de otro operador | 409 | No |
| `57014` | Consulta cancelada por el cliente | 499 | No |
| `P0002` | `SELECT … INTO STRICT` sin filas (id inexistente) | 404 | No |
| `40001` / `40P01` | Serialización / deadlock del motor | 409 + `Retry-After` | **Sí** |
| `23505` / `23503` | Unicidad / FK genuinas | 409 | No |
| `23505` sobre `ux_…__operacion` | **Doble aplicación de una operación bloqueada por el motor** | 409 | No — es la barrera funcionando |

---

# 2. Observaciones y decisiones de diseño

## 2.1 Casos que no encajan limpiamente en `cat_` / `tbl_` / `rel_`

**`tbl_inventario` — el caso importante.** Formalmente *parece* `rel_`: su PK es
`(producto_id, almacen_id)`, dos FK y nada más. Clasificarla como `rel_` sería **activamente
engañoso**: le diría a quien abra la base "esto es una tabla puente, sigue de largo", cuando es
la tabla más volátil y más crítica del sistema — donde vive el estado que la concurrencia puede
corromper. Su forma N:M es incidental; su propósito es custodiar existencias. Además incumple el
discriminador de `rel_` en los tres puntos: sus FK son `RESTRICT` no `CASCADE`, tiene estado
mutable propio, y es tabla **referenciada** por la bitácora. → **`tbl_`**.

**`tbl_operaciones` — señalado para tu ratificación.** No es catálogo, no es dato de
negocio y no relaciona entidades: es infraestructura de protocolo HTTP con TTL de 48 h. Ninguno
de los tres prefijos le queda natural. Como está prohibido inventar un cuarto, **`tbl_` es la
opción menos mala** (una fila por operación de API = transaccional).

**`cat_reglas_sku` — borderline sin conflicto.** Es configuración, no catálogo de negocio, pero
encaja en la definición de `cat_` ("información de referencia relativamente estática"). Se anota
solo para que no sorprenda verla junto a productos y clientes.

**`rel_orden_producto` — coincide con tu ejemplo.** No es una tabla puente pura: carga `cantidad`,
`precio_unitario_historico` e `importe_linea`. Es una *entidad asociativa*, el caso de libro de
`rel_`, y cumple el discriminador (`CASCADE` desde la orden).

**`tbl_renglones_importacion` — no es `rel_`.** Cascadea desde su lote, pero solo tiene un padre:
no relaciona dos entidades. → `tbl_`.

**Objetos que no son tablas.** La convención dada cubre tablas. Se extendió a constraints, índices,
triggers, funciones, vistas y secuencias con los prefijos de §1.1 — sin inventar prefijos de tabla,
que es lo prohibido.

## 2.2 Redundancias declaradas y su garantía

Toda desnormalización queda **declarada** y **protegida por el motor**. Una desnormalización
justificada pero sin garantía es un defecto, no una optimización.

| Redundancia | Justificación | Garantía |
|---|---|---|
| `cat_productos.sku_prefijo` duplica `cat_categorias.codigo` | Una columna generada no puede leer otra tabla; el SKU debe congelarse | FK `sku_prefijo → cat_categorias(codigo)` con `UPDATE RESTRICT` |
| `tbl_movimientos_inventario.fisica_antes/despues` | Bitácora autoauditable y de lectura O(1) | 3 `CHECK` de aritmética + tipo vs delta |
| `rel_orden_producto.nombre_historico`, `precio_unitario_historico` | Snapshot: cambiar el catálogo no reescribe órdenes | Trigger `trg_rel_orden_producto__sellar` los llena desde `cat_productos`; el cliente no los envía |
| `tbl_ordenes.monto_total` | Evita agregación por fila en listados y dashboard | Trigger de recálculo + guardián autovalidante que rechaza cualquier valor distinto de la suma real |
| `cat_categorias.consecutivo_sku` | Acuñación sin DDL dinámico ni `max()+1` con carrera | Autorreparable contra `cat_productos` + trigger de sincronización |

`sku_historico` en las partidas **se eliminó**: el SKU es inmutable por diseño y la FK es
`RESTRICT`, así que la copia solo podía divergir por error. Se resuelve por join en
`vw_orden_partidas`.

## 2.3 Cambios aplicados respecto al diseño previo

### Renombrados por convención

| Antes | Ahora | Motivo |
|---|---|---|
| `inventory` … `order_items` (12 tablas en inglés) | `cat_*` / `tbl_*` / `rel_*` en español | Convención impuesta |
| `stock_minimo` | `cantidad_minima` | Coherencia: las otras tres cantidades ya estaban en español |
| `tbl_llaves_idempotencia.endpoint` | `ruta` | Ídem |
| `fn_ajustar_stock` | `fn_ajustar_existencia` | Ídem |
| `es_stock_bajo` / `skus_stock_bajo` | `es_existencia_baja` / `productos_existencia_baja` | Ídem |
| `vw_kpis_dashboard` | `vw_indicadores_operacion` | "dashboard" aparecía traducido y sin traducir a 14 líneas de distancia |
| `origen_tipo` | `tipo_origen` | Paralelismo con `tipo_movimiento`: núcleo antes que calificador |
| `tbl_importacion_lotes` / `_renglones` | `tbl_lotes_importacion` / `tbl_renglones_importacion` | Paralelismo con `tbl_movimientos_inventario` |
| `tbl_lotes_importacion.tipo` | `tipo_lote` | Un `tipo` suelto no dice de qué |
| `rel_orden_producto.precio_unitario` | `precio_unitario_historico` | Evita `42702: column reference is ambiguous` al unir con `cat_productos` — y con ello el riesgo real de recalcular una orden enviada con el precio vigente |
| `version_ecc` | `version_concurrencia` | `ecc` es una abreviatura opaca en inglés (**requiere tu ratificación**, §2.5) |

### Defectos corregidos por la auditoría

La auditoría multi-agente produjo 23 hallazgos brutos → 17 confirmados tras refutación
adversarial → 13 tras fusión. **Tres eran críticos y habrían llegado a producción.**

**C1 · El índice único de idempotencia hacía inconfirmable toda orden multi-partida.**
`ux_tbl_movimientos__idempotencia` declaraba 1:1 lo que en realidad es 1:N: una petición produce
un movimiento por partida, todos con la misma llave, de modo que la segunda partida chocaba con
`23505`. Toda orden de 2+ productos era inconfirmable, inenviable e incancelable en cuanto .NET
mandaba `X-Idempotency-Key` — es decir, siempre. **Corrección:** unicidad de 4 columnas
`(llave, producto, almacén, tipo)`, y llave derivada por renglón en la importación.

**C2 · Embarque no-op silencioso y reserva huérfana permanente.** `fn_enviar_orden` y
`fn_cancelar_orden` no verificaban `IF NOT FOUND` tras el `UPDATE` del bucle, y nada impedía
mover `almacen_id` de una orden ya confirmada. Secuencia de falla: confirmar en `ALM-NTE` →
`UPDATE tbl_ordenes SET almacen_id = ALM-SUR` → enviar → 0 filas afectadas en silencio → la orden
queda `ENVIADA` (terminal), sin ningún movimiento de embarque, y la reserva vive para siempre en
`ALM-NTE` mermando `cantidad_disponible` sin forma de liberarla. **Corrección:** guardias
`IF NOT FOUND` en los tres bucles + `trg_tbl_ordenes__encabezado_inmutable`.

**C3 · La acuñación de SKU se trababa de forma permanente.** El incremento del contador era ciego
(`+1`) y vivía en la misma transacción que el `INSERT`. Si una semilla o una reimportación insertaba
un producto con consecutivo explícito sin actualizar el contador, cada alta nueva chocaba contra
`uq_cat_productos__acunacion`, el rollback revertía también el incremento, y la categoría quedaba
**imposible de dar de alta para siempre**, con un `23505` opaco que Polly reintentaba en balde.
**Corrección:** acuñación autorreparable con `greatest(contador, max real) + 1`, trigger de
sincronización `AFTER INSERT`, y `WM004` explícito para el consecutivo impuesto duplicado.

**A1 · El contexto GUC falsificaba la bitácora.** Ninguna función limpiaba el contexto al salir,
así que cualquier escritura posterior sobre `tbl_inventario` en la **misma transacción** heredaba
tipo, origen, `orden_id`, motivo, actor y llave de la operación anterior, quedando grabada como un
hecho falso e inmutable que `ck_…coherencia_origen` no podía detectar porque el par heredado era
internamente consistente. **Corrección:** `fn_limpiar_contexto_movimiento()` invocada antes de cada
`RETURN`, default de tipo corregido para el caso `delta_fisica = 0`, y
`ck_…tipo_vs_delta` como red declarativa.

**M-varios.** Errores de negocio migrados a la clase `WM`; validación de disponibilidad plegada
dentro del `UPDATE` para que la sobreventa se reporte como error de negocio y no como texto de
constraint; trazabilidad por renglón en la importación (`almacen_id`, `accion`,
`cantidad_aplicada`, `movimiento_id`); vistas de lectura para órdenes y partidas; fuentes de
agregación para la gráfica obligatoria del dashboard; `codigo_error` permitido en renglones
`OMITIDO`.

### Iteración de criterios de concurrencia, cancelación y trazabilidad

Tres decisiones previas entraron en conflicto con los nuevos criterios. Se identifican y resuelven:

**⚔️ Conflicto 1 — "cancelar el primer clic" contra el delta conmutativo.**
El ajuste rápido estaba diseñado como delta puro: dos clics en `+` = `+2`, y `E3` lo verificaba.
Cancelar la primera petición dejaría `+1` y el usuario perdería un clic real.
**Resolución:** el control pasa a *stepper con intención acumulada* (§3.5). La petición reemplazada
nunca cargaba la intención completa, así que cancelarla deja de ser destructivo. Se cumple la regla
literal — solo sobrevive la más reciente — sin perder movimientos. `E3` actualizada.

**⚔️ Conflicto 2 — "estado del movimiento" contra la bitácora inmutable.**
Se pidió que cada movimiento guarde su estado; la bitácora es estrictamente de solo inserción.
Almacenar un estado mutable la volvería manipulable y destruiría su valor probatorio.
**Resolución:** `estado` se **deriva** en `vw_movimientos_detalle` (`APLICADO` / `CONSUMIDO` /
`COMPENSADO`) a partir del ciclo de vida de la orden. Misma información, sin renunciar a la
inmutabilidad.

**⚔️ Conflicto 3 — "usuario responsable" contra el alcance sin autenticación.**
El alcance excluye autenticación, pero la trazabilidad exige atribución.
**Resolución:** `cat_usuarios` como registro de operadores **sin credenciales**. Se obtiene
atribución completa sin construir un sistema de identidad fuera de alcance. `fn_fijar_contexto_movimiento`
y el trigger de bitácora abortan con `WM014` si el usuario falta, no existe o está inactivo.

Cambios de esquema derivados:

| Cambio | Motivo |
|---|---|
| Tabla `cat_usuarios` + `seq_cat_usuarios` | Atribución de cada movimiento |
| `creado_por text` → `usuario_id` / `creado_por_usuario_id` FK `RESTRICT` en bitácora, órdenes, lotes e idempotencia | Un texto libre no es trazabilidad |
| `uuid_movimiento` con unicidad | Identificador público estable del movimiento |
| `desactivado_en` + `desactivado_por_usuario_id` + `CHECK` de sello en los 5 catálogos | Soft-delete auditado |
| `fk_tbl_renglones_importacion__productos`: `SET NULL` → `RESTRICT` | Era la única FK que podía perder información histórica |
| `tbl_llaves_idempotencia` gana `alcance`, `llave_supersede`, `efecto`, `usuario_id`, estatus `CANCELADO`/`SUPERSEDIDO` y unicidad parcial sobre `llave_supersede` | Protocolo de supersesión |
| `fn_reclamar_supersesion`, `fn_verificar_vigencia`, `fn_sellar_idempotencia`, `fn_sellar_baja_logica`, `fn_bloquear_borrado` | Idem |
| `ix_tbl_movimientos_inventario__usuario_fecha` | "Qué hizo el usuario X y cuándo" es consulta de auditoría de primer orden |
| Vista `vw_aportacion_por_usuario` | Evidencia de que los movimientos concurrentes se conservan por separado y suman |
| `p_actor text` → `p_usuario_id bigint` en las cuatro primitivas | Ídem |

### Tercera iteración — la idempotencia deja de depender del cliente

**⚔️ Conflicto 4 — la garantía estaba en el lugar equivocado.** El diseño anterior acuñaba la llave
de idempotencia **por petición**. Un segundo clic sobre el mismo modal producía una llave distinta,
así que el backend lo trataba como una operación nueva y **lo aplicaba dos veces**. La maquinaria
de idempotencia existía y era correcta, pero una decisión del cliente la volvía inoperante justo en
el escenario que debía cubrir: conexión lenta, modal abierto, segundo clic.

**Resolución.** `id_operacion` identifica una **intención**, no una petición: se acuña una vez y se
reutiliza en todos los reenvíos. Y la garantía se ancla en el motor con
`ux_tbl_movimientos_inventario__operacion`, que hace **físicamente imposible** materializar dos
veces la misma operación, con o sin cooperación del cliente.

**Se elimina el protocolo de supersesión completo.** Cancelar y compensar era la forma indirecta de
evitar duplicados; con idempotencia real sobra, y con él desaparecen el `40P01` estructural, la
compensación transitiva, `deuda`, `compensado_por`, `llave_supersede`, `efecto`, los estatus
`SUPERSEDIDO`/`CANCELADO`, `fn_reclamar_supersesion`, `fn_verificar_vigencia` y la fase 0b. La
cancelación del frontend se conserva con su alcance honesto: **UX y ahorro de tráfico, nunca
integridad.**

| Cambio de esquema | Motivo |
|---|---|
| `tbl_llaves_idempotencia` → **`tbl_operaciones`** (PK `id_operacion`, `+intentos`, `−llave_supersede`, `−compensado_por`, `−deuda`, `−efecto`) | Una fila por intención, no por petición |
| `tbl_movimientos_inventario.llave_idempotencia` → **`id_operacion NOT NULL`** | Ningún movimiento puede quedar fuera del control de idempotencia |
| `ux_…__idempotencia` (parcial) → **`ux_…__operacion`** (total) | La barrera definitiva; ya no admite filas sin operación |
| `fn_reservar_operacion`, `fn_sellar_operacion`, `fn_cerrar_operacion_fallida`, `fn_barrer_operaciones_colgadas` | Fases 0/1/2 + recuperación de operaciones colgadas |
| `p_llave_idem` → `p_id_operacion` **obligatorio** en las cuatro primitivas | Idem |
| `X-Idempotency-Key` → `X-Operation-Id`; se elimina `X-Supersedes` | Refleja el cambio semántico |

### Tercera ronda de auditoría — y la ejecución que la revisión estática no sustituye

20 hallazgos brutos → 18 confirmados → 14 tras fusión. El primero invalidaba todo lo demás:

| Sev. | Defecto | Corrección |
|---|---|---|
| 🔴 | **`0002_logica.sql` no compilaba.** Tres funciones abrían su cuerpo con `as $` en vez de `as $$`. La migración abortaba, así que **no existía ni la barrera 1 ni el trigger de bitácora**, y el índice de la barrera 2 protegía una tabla que nadie escribía: cero garantía. Causa raíz: en JavaScript, `$$` dentro del reemplazo de `String.replace` es un escape que produce **un solo** `$`; mis parches automatizados corrompieron el archivo en silencio | Tres caracteres. Y, sobre todo, **ejecutar el SQL**: ninguna de las dos auditorías estáticas anteriores lo detectó |
| 🔴 | **La importación confirma por partes**, así que `FALLIDO` no significaba "no se aplicó nada". Un reintento que reseleccionaba el archivo acuñaba un id nuevo y **reaplicaba los 3 000 renglones** sin violar ninguna restricción | `id_operacion` derivado del **contenido**, `NOT NULL` y único en el lote, reanudación desde el primer renglón no-`OK`, un `SAVEPOINT` por renglón, y exclusión del barrido |
| 🔴 | **El hash incluía campos que no son la intención** (`motivo`, `version_esperada`). Editar el motivo entre clics producía `WM015` permanente; el usuario cerraba el modal, acuñaba un id nuevo y **se aplicaba dos veces**. Un hash demasiado amplio causa la duplicación que pretende evitar | Definición normativa del hash: superconjunto de las columnas de `ux_…__operacion` **y nada más**; prohibido re-acuñar tras `WM015` |
| 🟠 | **`id_operacion` sin espacio de nombres por operador.** Dos operadores con el mismo id y cuerpo idéntico → el segundo recibía `200` con la respuesta del primero y **su movimiento desaparecía sin error** | Prefijo `<usuario_id>:` obligado por `ck_…__formato` y `ck_…__prefijo_actor`, más el veredicto `CONFLICTO_DE_ACTOR` |
| 🟠 | **`alcance` y `ruta` se almacenaban y nunca se comparaban.** `/ordenes/12/confirmar` y `/ordenes/12/enviar` tienen ambos cuerpo vacío: con el mismo id, el envío recibía `200` con la respuesta de la confirmación y **el embarque no ocurría jamás** | Se comparan los tres: hash, alcance y ruta |
| 🟠 | **La bitácora aceptaba `INSERT` directo.** El trigger de inmutabilidad solo cubre `UPDATE`/`DELETE`/`TRUNCATE`, y el rol que la API necesita para operar era el mismo que le permitía falsificar el historial | `0003_permisos.sql`: el trigger pasa a `SECURITY DEFINER` y se revoca `INSERT` a `wms_api`. **Verificado**: el `INSERT` falsificador recibe *permission denied* y la API sigue operando |
| 🟠 | **El barrido decidía por reloj** y podía marcar `FALLIDO` una operación viva o ya aplicada | No toca operaciones con rastro en la bitácora ni importaciones; la purga respeta la misma regla |
| 🟠 | **Rutas sin movimiento** (alta de orden) no tenían barrera de motor y su lápida expiraba a 48 h | `tbl_ordenes.id_operacion` `NOT NULL` + único |
| 🟡 | El barrido y los timeouts que el diseño prometía **no estaban instalados** | `0003_permisos.sql`: `statement_timeout`, `idle_in_transaction_session_timeout`, `lock_timeout` y el job de `pg_cron` |
| 🟡 | Índice redundante sobre `id_operacion` sola | Eliminado: el único ya la lleva como columna principal |

**Residual declarado.** Para rutas que no generan movimiento y no tienen unicidad natural —el alta
de producto— la protección es solo la barrera 1, con una ventana de 48 h. Un reintento pasada esa
ventana no es un reintento. Se documenta en vez de fingir que está cubierto.

### Segunda ronda de auditoría — defectos del protocolo de supersesión (histórico)

> El protocolo auditado en esta ronda **se eliminó** en la tercera iteración. Se conserva el
> registro porque documenta defectos reales encontrados y porque tres de las correcciones
> (autoría de transiciones, `TRUNCATE`, borrado de transaccionales) siguen vigentes.

24 hallazgos brutos → 17 confirmados tras refutación. Los corregidos:

| Sev. | Defecto | Corrección |
|---|---|---|
| 🔴 | **Deadlock `40P01` en el caso nominal del doble clic.** La supersesión tomaba el lock de la llave ajena dentro de la transacción de trabajo, invirtiendo el orden respecto de la petición reemplazada. Tres lentes lo reprodujeron. La víctima la elegía el temporizador: si moría el reemplazante, su marca `SUPERSEDIDO` se revertía y **ganaba el clic viejo** | Fase 0b en conexión aparte con `COMMIT` inmediato; orden de locks invariante **inventario → llave propia** |
| 🔴 | **La compensación no era transitiva.** En `A←B←C`, si `B` era reemplazada tras heredar la deuda de `A`, nadie la asumía y `C` aplicaba de más | Columna `deuda`: cada llave graba lo que heredó, y su sucesora lo hereda si la abandonan |
| 🔴 | **Las transiciones de orden no registraban su autor.** Una cancelación en `BORRADOR` no genera movimientos: su autor desaparecía | `confirmado_por_usuario_id`, `enviado_por_usuario_id`, `cancelado_por_usuario_id` con `CHECK` de sello |
| 🟠 | **`TRUNCATE` vaciaba la bitácora "inmutable".** No dispara triggers de fila | Trigger `BEFORE TRUNCATE … FOR EACH STATEMENT` en bitácora, órdenes e inventario |
| 🟠 | **`ON DELETE CASCADE` permitía borrar órdenes en `BORRADOR` y lotes fallidos sin rastro** | Trigger `BEFORE DELETE` que bloquea el borrado de entidades transaccionales |
| 🟠 | **Reactivar un catálogo borraba `desactivado_en` y su autor**, destruyendo la historia de la baja | `CHECK` unidireccional; el sello sobrevive a la reactivación |
| 🟠 | **El índice único sobre `llave_supersede` estallaba con `23505`** fuera de todo manejo, porque el `ON CONFLICT (llave)` de la fase 0 no lo arbitra | Se elimina; se sustituye por la guardia `compensado_por IS NULL` en un `UPDATE` atómico |
| 🟠 | **`RollbackAsync` sin protección** suplantaba la excepción original sobre una conexión rota, y el `throw;` nunca se ejecutaba | `try/catch` alrededor del rollback + `conn.Discard()` |
| 🟠 | **El refetch de la lista pisaba la intención pendiente**, provocando doble aplicación | `baseConfirmada` y `deltaIntencion` son estados separados; `deltaIntencion` vive fuera de la caché de queries |
| 🟠 | **Deshabilitar el control durante la mutación anulaba la supersesión**: sin segundo clic no hay nada que reemplace al primero | El control nunca se deshabilita |
| 🟡 | `fn_sellar_baja_logica` aceptaba autor `NULL` y fecha arbitraria del cliente | La fecha la pone el motor; el autor es obligatorio (`WM014`) |
| 🟡 | `fn_cancelar_orden` fijaba `ctx_usuario_id` por la puerta trasera, evadiendo la validación | Usa `fn_fijar_contexto_movimiento`, que valida |
| 🟡 | `SELECT … INTO STRICT` dejaba escapar `P0002` crudo → 500 en vez de 404 | Añadido al mapeo SQLSTATE → HTTP |
| 🟡 | La llave `EN_PROCESO` huérfana no tenía recuperación | Índice parcial + job de `pg_cron` que cierra como `FALLIDO` tras 5 min |

### Hallazgos descartados por el verificador adversarial

Se registran para dejar constancia de que fueron evaluados y por qué no se aplicaron:

- *"`tbl_inventario` debería llevar `rel_`"* — premisa falsa: incumple el discriminador de `rel_`
  en sus tres puntos.
- *"El ajuste rápido no tiene control de concurrencia efectivo"* — el `IF NOT FOUND` no es código
  muerto, es el detector del conflicto optimista; `fn_incrementar_version_concurrencia` **asigna**
  en vez de sumar, luego el "doble salto" no existe.
- *"`tbl_llaves_idempotencia` no serializa dos peticiones simultáneas"* — la PK es sobre `llave`
  sola; la corrección propuesta (`unique (llave, ruta)`) habría **debilitado** la unicidad.
- *"La importación no es idempotente a nivel de lote"* — `pk_tbl_llaves_idempotencia` ya lo impide.
- *"Nombres de constraint abreviados"* — cosmético; se corrigió de todos modos por consistencia.

## 2.4 Ambigüedades del enunciado y su resolución

El enunciado declara que las ambigüedades son intencionales. Se identificaron 12 y se resolvieron
todas; las cuatro marcadas ✅ fueron ratificadas por el usuario.

| # | Ambigüedad | Resolución |
|---|---|---|
| ✅ A1 | Formato del SKU no definido | `[CATEGORÍA 4]-[CONSECUTIVO 4]`, ancho fijo 9, acuñado por el motor |
| ✅ A2 | Rol del código de almacén frente al SKU | Localizador externo (`ELEC-0001@ALM-NTE`); el SKU no lleva almacén, o dejaría de identificar inequívocamente un producto |
| ✅ A3 | Cuándo afecta la orden al inventario | Reserva al confirmar, descuento al enviar, liberación al cancelar |
| ✅ A4 | Dónde vive la mutación atómica | Híbrido: primitiva en PL/pgSQL, orquestación en .NET |
| A5 | ¿Se puede borrar producto/categoría con inventario? | No. `RESTRICT` en toda relación transaccional; baja lógica |
| A6 | ¿Precio del catálogo o de la orden? | La partida congela precio y nombre; el catálogo no reescribe historia |
| A7 | Moneda no especificada | Monomoneda MXN. `numeric(14,2)`, jamás `float`. Multimoneda fuera de alcance |
| A8 | ¿Cantidades enteras o fraccionarias? | Enteras (piezas). `integer` |
| A9 | ¿Se puede cancelar una orden enviada? | No. `ENVIADA` es terminal; una devolución sería otro flujo |
| A10 | Duplicados en importación | Modo explícito por lote: `SOLO_ALTA` (duplicado = `OMITIDO` con código) o `ALTA_O_ACTUALIZA` |
| A11 | ¿Todo-o-nada en la importación? | Éxito parcial por renglón, con reporte consultable después |
| A12 | ¿Los reintentos requieren tratamiento? | Sí, obligatorio. `X-Operation-Id` acuñado **por intención** (no por petición), con huella del cuerpo y TTL 48 h, respaldado por un índice único en la bitácora |

## 2.5 Puntos ratificados por el usuario

Los ocho puntos siguientes fueron **confirmados** el 2026-08-21 y ya están aplicados en el DDL.

| # | Punto | Resolución aplicada |
|---|---|---|
| 1 | `tbl_operaciones` con prefijo `tbl_` — es infraestructura, no dato de negocio | Aceptar `tbl_`; no hay mejor opción sin inventar un cuarto prefijo |
| 2 | `tbl_inventario` con prefijo `tbl_` y no `rel_` | Aceptar `tbl_` (§2.1) |
| 3 | `rel_orden_producto` en singular-singular (tu ejemplo) frente a `rel_ordenes_productos` en plural como el resto | **Mantener tu ejemplo.** El costo es un `[Table]` en EF Core; cambiar tu nomenclatura explícita sin preguntarte sería peor |
| 4 | `version_ecc` → `version_concurrencia`. Nombraste `version_ecc` en el brief original | Renombrar: `ecc` es una abreviatura opaca en inglés y contradice la convención que acabas de fijar. Reversible con un `sed` |
| 5 | `cat_productos.estatus` (3 valores) frente a `es_activo` (booleano) en los otros 4 catálogos | Mantener la diferencia por cardinalidad, documentada como excepción explícita en el DDL |
| 6 | Catálogo de códigos de error de importación (`SKU_YA_EXISTE`, `DUPLICADO_EN_ARCHIVO`, `MODO_SOLO_ALTA`, `CATEGORIA_INEXISTENTE`, `ALMACEN_INEXISTENTE`, `CANTIDAD_INVALIDA`, `PRECIO_INVALIDO`) | Ratificar: el frontend agrupará por ellos y después son contrato |
| 7 | Gráfica del dashboard a demostrar: barras por almacén o serie temporal diaria | Ambas. La serie es la más demostrativa del flujo completo, y exige que la semilla distribuya fechas |
| 8 | ¿Cerrar la escritura directa a `tbl_inventario` con `revoke` + funciones `SECURITY DEFINER`? | Sí para la entrega final; elimina de raíz la falsificación de bitácora. Obliga a que `ALTA_O_ACTUALIZA` exprese cantidades absolutas como delta calculado bajo el lock |

---

# 3. Especificación de la solución

## 3.1 Arquitectura .NET 8 — Vertical Slice + CQRS

```text
src/
  Wms.Api/                       Minimal API, middleware, composición
    Middleware/IdempotenciaMiddleware.cs
    Middleware/ExcepcionesPostgresMiddleware.cs     SQLSTATE → ProblemDetails RFC 7807
  Wms.Application/               un slice por caso de uso
    Inventario/AjustarExistencia/{Comando,Handler,Validador,Respuesta}.cs
    Inventario/ConsultarTablero/ ConsultarMovimientos/
    Ordenes/CrearOrden/ ConfirmarOrden/ EnviarOrden/ CancelarOrden/
    Catalogos/{Categorias,Almacenes,Productos,Clientes}/
    Importacion/DescargarPlantilla/ ProcesarImportacion/ ConsultarResultado/
    Indicadores/ObtenerIndicadores/
    Comun/Sku/{AnalizadorSku,ReglaSku,ResultadoAnalisis}.cs
  Wms.Infrastructure/
    Persistencia/{SesionBd,Repositorios}/           Npgsql; Dapper lectura, EF Core catálogos
    Resiliencia/PoliticasPolly.cs
  Wms.Domain/                    entidades, invariantes, errores tipados
tests/
  Wms.UnitTests/                 xUnit + FluentAssertions + NSubstitute
  Wms.IntegrationTests/          xUnit + Testcontainers.PostgreSql
web/                             React 18 + TS + Vite + Tailwind + shadcn/ui + Recharts
  e2e/                           Playwright
db/
  migraciones/0001_esquema.sql  0002_logica.sql  0003_permisos.sql
  pruebas/humo_idempotencia.sql  verificar.sh
  semilla.sql
```

**Reparto de responsabilidades (decisión A4).** MediatR gobierna validación, parsing de SKU,
idempotencia y mapeo de errores. La base expone `fn_ajustar_existencia`, `fn_confirmar_orden`,
`fn_enviar_orden` y `fn_cancelar_orden` como **única primitiva de mutación**: ninguna ruta de
código puede violar el invariante, y la sección crítica cabe en un solo round-trip.

**Polly.** Reintento exponencial con jitter (3 intentos, base 50 ms) **solo** para `40001`,
`40P01` y `55P03`. Nunca reintenta la clase `WM` ni el 409 de idempotencia: son deterministas y
reintentarlos solo quema presupuesto. Circuit breaker de 5 fallas consecutivas / 30 s sobre la
conexión; timeout de 5 s por comando de inventario.

## 3.2 Contrato de endpoints

**Encabezados obligatorios en toda mutación:** `X-Operation-Id` (el `id_operacion`, acuñado por
intención y reutilizado en cada reenvío), `X-Usuario-Id` y `X-Scope`.

| Método | Ruta | Notas |
|---|---|---|
| `GET` | `/api/salud` | sonda de arranque |
| `GET` | `/api/catalogos/{recurso}` | `recurso` ∈ {categorias, almacenes, clientes, usuarios, productos} · lista blanca, nunca concatenación cruda · `soloVigentes`, `pagina`, `porPagina` |
| `POST` | `/api/catalogos/{recurso}` | **alta reservada al operador 1 (SISTEMA)**, comprobada aquí y exigida por el motor · `X-Operation-Id` obligatorio |
| `PUT` | `/api/catalogos/{recurso}/{id}` | corrección · **cualquier operador identificado** · `{campos, versionEsperada}` · la versión es obligatoria; una obsoleta devuelve `WM008` en vez de pisar |
| `POST` | `/api/catalogos/{recurso}/{id}/desactivar` · `/reactivar` | baja lógica y su reverso · nunca borra · reactivar conserva el sello de la baja anterior |
| `GET` | `/api/productos/buscar?q=` | búsqueda de tecleo; mínimo 2 caracteres, tope `limite` (20 por omisión) |
| `GET` | `/api/sku/analizar?sku=ELEC-0001` | análisis contra la regla activa |
| `GET` | `/api/inventario` | filtros `almacenId`, `q`, `soloExistenciaBaja` · `pagina`, `porPagina` |
| `GET` | `/api/inventario/exportar` | CSV al vuelo con **los mismos filtros y sin paginar**: trae el conjunto completo · solo SUPERVISOR y SISTEMA |
| `POST` | `/api/inventario/ajustar` | **`X-Operation-Id` obligatorio** · `{productoId, almacenId, delta, tipoMovimiento, motivo, versionEsperada?}` · repetir el mismo id devuelve la respuesta original sin volver a aplicar |
| `POST` | `/api/inventario/establecer` | ajuste a cantidad **objetivo** (conteo físico); la conversión objetivo→delta la hace el motor bajo el row lock |
| `GET` | `/api/inventario/movimientos` | filtros `productoId`, `almacenId`, `usuarioId`, `sku`, `idOperacion`, `desde`, `hasta`, `tipo` · `pagina`, `porPagina` |
| `GET` | `/api/inventario/movimientos/{id}` | detalle de un movimiento |
| `POST` | `/api/inventario/movimientos/{id}/desactivar` | **reservado al operador 1**, exigido en el motor · asienta una `REVERSA`, no muta la bitácora |
| `GET` | `/api/ordenes` | filtros `estatus`, `clienteId`, `almacenId` · `pagina`, `porPagina` |
| `GET` | `/api/ordenes/{id}/partidas` | detalle de una orden; conjunto acotado, sin paginar |
| `POST` | `/api/ordenes` | se crea en `BORRADOR` |
| `POST` | `/api/ordenes/{id}/{confirmar\|enviar\|cancelar}` | **`X-Operation-Id` obligatorio** |
| `GET` | `/api/importacion/plantilla` | descarga la plantilla CSV |
| `POST` | `/api/importacion` | multipart + `X-Operation-Id` · devuelve el detalle completo del archivo recién procesado |
| `GET` | `/api/importacion/{id}` | resultado persistido; los renglones van **paginados** (`pagina`, `porPagina`) |
| `GET` | `/api/indicadores` | escalares, series y los dos KPIs (mayor demanda, existencia insuficiente) · `dias`, `topN` |

## 3.3 Importación masiva

Plantilla de hoja única con encabezados fijos:

```text
categoria_codigo | nombre_producto | descripcion | precio_unitario | estatus
                 | almacen_codigo  | cantidad_inicial | cantidad_minima
```

- **El SKU no va en la plantilla.** Lo acuña el servidor. Esto elimina de raíz la colisión de SKUs
  entre archivos preparados por distintas personas — el modo de falla más probable de una carga
  masiva con identificadores capturados a mano.
- `categoria_codigo` y `almacen_codigo` deben existir; si no, el renglón es `ERROR` con
  `CATEGORIA_INEXISTENTE` / `ALMACEN_INEXISTENTE`.
- `SOLO_ALTA`: un producto ya existente con el mismo nombre en la misma categoría produce
  `OMITIDO` + `SKU_YA_EXISTE`.
- `ALTA_O_ACTUALIZA`: actualiza precio, descripción y estatus, y **suma** `cantidad_inicial` como
  movimiento `IMPORTACION`.
- **Dos pasadas.** Primero se valida el archivo completo en memoria y se devuelve el reporte; solo
  después se aplica. Un archivo 100 % inválido nunca abre transacción.
- Éxito parcial por renglón; chunks de 500 renglones por transacción para acotar la duración del
  lock.
- Cada renglón guarda `carga_original` en `jsonb`, su `accion`, su `cantidad_aplicada` y el
  `movimiento_id` resultante: el resultado es navegable, no solo un contador.

### Idempotencia de la importación — el caso difícil

Es la única operación cuyo trabajo **se confirma por partes** (chunks de 500 renglones), así que
`FALLIDO` deja de significar "no se aplicó nada". Requiere reglas propias:

1. **El `id_operacion` del lote se deriva del contenido**, no del momento de seleccionar el
   archivo: `<usuario_id>:imp-<sha256(archivo)[..16]>-<modo>`. Si se acuñara al abrir el
   selector, el usuario que reintenta tras un corte reseleccionaría el archivo, acuñaría un id
   nuevo, y las llaves por renglón frescas **no colisionarían** con los renglones ya aplicados:
   los 3 000 renglones se aplicarían otra vez sin violar ninguna restricción.
2. `tbl_lotes_importacion.id_operacion` es **`NOT NULL` y único**. El reintento hace
   `INSERT … ON CONFLICT DO NOTHING` y luego **lee** la fila: **reanuda** desde el primer
   `numero_renglon` que no esté `OK`. La llave por renglón se construye con el id **leído**,
   nunca con uno armado de nuevo.
3. **Cada renglón corre bajo su propio `SAVEPOINT`.** Un `23505` sobre `ux_…__operacion` significa
   "este renglón ya se aplicó": `rollback to savepoint` y se marca `OMITIDO` con
   `codigo_error = 'YA_APLICADO'`. Sin el savepoint, ese `23505` mataría el chunk entero de 500 y
   la reimportación no avanzaría nunca.
4. **La importación queda fuera del barrido** (`alcance not like 'importacion:%'`): puede durar
   legítimamente más que el umbral de 5 minutos, y su avance real vive en
   `tbl_lotes_importacion.estatus`.

Cada renglón deriva su llave como `<id_operacion_lote>:<numero_renglon>` porque dos renglones del
mismo archivo pueden tocar legítimamente el mismo par producto/almacén, y compartir `id_operacion`
los haría chocar entre sí.

## 3.4 Frontend

Identidad visual limpia estilo Linear: tipografía nítida, contraste balanceado, espaciado
consistente, sin cromo decorativo. Obligatorios en toda vista de datos: **estados vacíos**,
**skeleton loaders** y **toasts** que distingan el éxito del fallo por concurrencia.

Vistas: catálogo de categorías, catálogo de almacenes, productos (con combobox de categoría
alimentado del catálogo, nunca texto libre), tablero de inventario con **ajuste rápido `+`/`−`
en la propia fila**, órdenes con su ciclo de vida, movimientos históricos, importación, y
dashboard con Recharts.

**Ajuste rápido.** Ver §3.5: el control es un *stepper* con intención acumulada, no un disparador
de peticiones por clic.

## 3.5 Ciclo de vida de una operación

### Cuándo se acuña el `id_operacion`

Esta tabla es el contrato entre el frontend y la garantía del backend. Acuñar mal el
`id_operacion` es el único error del cliente capaz de producir un duplicado — y aun así lo detiene
el índice único, con `409` en vez de doble aplicación.

| Control | Se acuña al | Se reutiliza en | Se invalida cuando |
|---|---|---|---|
| **Modal de movimiento** | abrir el modal | **cada clic en Confirmar**, cada reintento por timeout, cada reconexión | la operación se aplica (`200`), o el usuario **cambia la cantidad** |
| **Stepper `+`/`−`** | primer clic tras el último asentamiento | los reenvíos de ese mismo lote acumulado | el lote se aplica |
| **Acciones de orden** | abrir el diálogo de confirmar/enviar/cancelar | reintentos de esa acción | la acción se aplica |
| **Importación** | seleccionar el archivo | reintentos de la subida | el lote se procesa |

### El caso del modal, paso a paso

```text
El usuario abre el modal        → el cliente acuña  id_operacion = ABC123
Cantidad = 2, clic en Confirmar → POST  X-Operation-Id: ABC123   {producto:123, delta:+2}
La red se atasca 5 s, sin respuesta.  El botón sigue habilitado.
El usuario vuelve a hacer clic  → POST  X-Operation-Id: ABC123   (EL MISMO)
                                        ↓
   backend, fase 0:  ON CONFLICT DO NOTHING → 0 filas
     ├─ la primera sigue corriendo   → EN_CURSO      → 409 + Retry-After
     └─ la primera ya confirmó       → YA_COMPLETADA → 200 con la respuesta original

Resultado:  cantidad_base + 2        Movimientos generados: 1
NUNCA:      cantidad_base + 2 + 2
```

El campo de **cantidad se congela** mientras hay una operación en vuelo: cambiarla sería una
intención distinta y acuñaría un `id_operacion` nuevo, con lo que ambas se aplicarían. El **botón
no se congela**: reintentar debe ser posible y es seguro.

### El caso del stepper: la integridad no depende del reloj

El `debounce` de 250 ms es **optimización de tráfico, no garantía**. Da igual si dispara o no:

| Ritmo de los clics | Operaciones emitidas | Movimientos | Existencia final |
|---|---|---|---|
| 3 clics en 100 ms | 1 operación de `+3` | 1 | `base + 3` |
| 3 clics en 10 s | 3 operaciones de `+1` | 3 | `base + 3` |
| 3 clics, la 1.ª reintentada 4 veces por timeout | 3 operaciones | 3 | `base + 3` |

Los deltas conmutan y cada operación es idempotente, así que **el resultado es el mismo en los tres
casos**. Ninguna ventana de tiempo participa en la corrección.

### Dos usuarios sobre el mismo producto

Son intenciones distintas, con `id_operacion` distintos: **ambas se contabilizan**, y cada una deja
su propio renglón auditable.

| `id_operacion` | `usuario_id` | `producto_id` | `delta_fisica` | `creado_en` |
|---|---|---|---|---|
| `AAA` | 10 | 123 | `+2` | 14:02:11.331 |
| `BBB` | 20 | 123 | `+3` | 14:02:11.487 |

Resultado: `base + 2 + 3`. Si el usuario 10 reintenta `AAA`, **no vuelve a sumar 2**.

### Papel de la cancelación en el frontend

Se conserva, con su alcance real declarado:

| Mecanismo | Para qué sirve | Para qué **no** sirve |
|---|---|---|
| `AbortController` | Dejar de esperar una respuesta que ya no interesa; liberar la conexión | Revertir algo que el backend ya aplicó |
| `debounce` | Reducir peticiones accidentales | Impedir duplicados |
| `id_operacion` + índice único | **Impedir duplicados** | — |

Regla explícita: **un abort nunca se interpreta como "no se aplicó"**. Ante un abort o un timeout,
el cliente reenvía la **misma** operación; el backend responde con la respuesta original si ya se
aplicó, y la aplica si no. Nunca se deduce el estado del servidor.

### Reglas de estado del cliente

- `deltaIntencion` (stepper) vive **fuera de la caché de queries**: un refetch actualiza solo la
  base, nunca la intención pendiente. Mezclarlas provocaría doble aplicación al siguiente envío.
- Solo la respuesta de la **operación vigente** actualiza el estado; las tardías se ignoran.
- Ante cualquier fallo terminal se refresca el alcance desde el servidor.
- El control **nunca se deshabilita**; se muestran los estados `pendiente`, `guardando`,
  `guardado`, `reintentando` y `fallido`, para que una cifra optimista nunca se presente como
  definitiva.
- Intención pendiente al desmontar: *flush* inmediato en la limpieza del efecto, y aviso en
  `beforeunload`. Si no alcanza a salir, se pierde — pero la UI nunca dijo que estaba guardada.

## 3.6 Transacciones, `id_operacion` y manejo de errores

### Las tres fases

| Fase | Conexión | Qué hace | Si el proceso muere aquí |
|---|---|---|---|
| **0 · Reserva** | Propia, `COMMIT` inmediato | `fn_reservar_operacion` → veredicto | La operación queda `EN_PROCESO`; el barrido la cierra como `FALLIDO` y vuelve a ser reejecutable |
| **1 · Trabajo** | Principal | Mutación → sellado → `COMMIT` | Rollback implícito del servidor; nada aplicado; sigue `EN_PROCESO` → barrido |
| **2 · Cierre en fallo** | Propia | `fn_cerrar_operacion_fallida` → `FALLIDO` | Igual que arriba: el barrido la recoge |

**La fase 0 no puede vivir dentro de la transacción de trabajo.** Por MVCC una fila insertada y no
confirmada es invisible para las demás sesiones: dos reenvíos simultáneos de la misma operación no
se verían el uno al otro y ambos ejecutarían. Chocarían igual contra el índice único del movimiento
—la barrera 2—, pero con un `23505` feo en vez de un `409` limpio.

**La fase 2 tampoco.** Tras un fallo la transacción principal está abortada y no admite más
sentencias: el cierre debe viajar por una conexión sana.

### Estructura obligatoria de todo comando

```csharp
// FASE 0 — conexión propia, COMMIT inmediato.
var reserva = await idempotencia.ReservarAsync(idOperacion, alcance, ruta, hash, usuarioId, ct);
switch (reserva.Veredicto)
{
    case "YA_COMPLETADA":  return reserva.RespuestaOriginal;          // 200, sin efectos
    case "EN_CURSO":       return Problema(409, "WM013", retryAfter: 1);
    case "CARGA_DISTINTA": return Problema(409, "WM015");
}

// FASE 1 — transacción de trabajo.
await using var tx = await conn.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
try
{
    resultado = await conn.QuerySingleAsync<InventarioDto>(
        "select * from wms.fn_ajustar_existencia(@producto, @almacen, @delta, @tipo, @usuario, @idOperacion, ...)",
        parametros, tx);

    // Sellado DENTRO de la transacción: si el COMMIT falla, el sello se
    // revierte con todo y la operación sigue siendo reejecutable.
    await conn.ExecuteAsync("select wms.fn_sellar_operacion(@idOperacion, 200, @cuerpo)", sello, tx);

    await tx.CommitAsync(CancellationToken.None);   // el COMMIT nunca se cancela
}
catch (Exception ex)
{
    try { await tx.RollbackAsync(CancellationToken.None); }
    catch (Exception exRollback)
    {
        // Sobre una conexión ya rota el rollback vuelve a lanzar y suplantaría
        // la excepción original. El servidor ya abortó la transacción por su
        // cuenta; basta descartar la conexión y registrar.
        logger.LogWarning(exRollback, "Rollback fallido; se descarta la conexión");
        conn.Discard();
    }
    // FASE 2 — conexión propia. Deja la operación REEJECUTABLE con el mismo id.
    await idempotencia.CerrarFallidaAsync(idOperacion, CodigoHttp(ex), ex.Message);
    throw;
}
```

**El sellado va dentro de la transacción de trabajo, y eso es deliberado.** Si estuviera fuera,
existiría un instante en que el movimiento está confirmado y la operación aún figura `EN_PROCESO`:
un reenvío recibiría `409` en vez de la respuesta correcta, y el barrido acabaría marcando como
`FALLIDO` algo que sí se aplicó. Dentro de la transacción, **movimiento y sello confirman o
fracasan juntos**.

### Orden de locks

Dentro de toda transacción de trabajo: **`tbl_inventario` primero**, y en los bucles de orden
`ORDER BY producto_id`. `tbl_operaciones` no se toca dentro de la transacción salvo por el sellado
final, que afecta a una fila propia que nadie más disputa. No hay dos clases de recurso tomadas en
órdenes opuestos, que es lo que generaba el `40P01` del diseño anterior.

### Qué ocurre ante cada modo de fallo

| Fallo | Comportamiento | ¿Puede duplicar? |
|---|---|---|
| Error de validación | Excepción antes de tocar la BD; `ROLLBACK` trivial; `422`; operación `FALLIDO` | No |
| Falla la tercera de tres escrituras | `catch` → `ROLLBACK` → las dos primeras se revierten | No |
| Pérdida de conexión | El backend detecta el socket muerto y aborta: rollback implícito | No |
| `RollbackAsync` falla | Conexión rota; el servidor ya abortó. Se descarta del pool | No |
| Cancelación del cliente | `RequestAborted` → `57014` → `ROLLBACK`. Nada aplicado | No |
| **Cancelación justo al confirmar** | Ventana irreducible: PostgreSQL no aborta un `COMMIT`. La operación queda aplicada aunque el cliente no vea la respuesta | **No** — el reenvío del mismo `id_operacion` devuelve la respuesta original |
| **Timeout del cliente con el backend procesando** | Igual que arriba | **No** — mismo mecanismo |
| Excepción dentro de una función PL/pgSQL | Es una sola sentencia: su fallo revierte su efecto completo | No |
| Bug que ejecute dos veces la misma operación | El segundo movimiento viola `ux_…__operacion` → `23505` → rollback de todo | **No** |

`CommitAsync` y `RollbackAsync` se invocan con `CancellationToken.None` **a propósito**: cancelar el
cierre de una transacción deja la conexión en estado indefinido, que es exactamente el problema que
se intenta evitar.

### Reintentos

Polly reintenta `40001`, `40P01` y `55P03` **con el mismo `id_operacion`**: la operación quedó
`FALLIDO`, la reserva la readmite como `NUEVA` y el reintento es seguro por construcción. No
reintenta la clase `WM` ni `23505`: son deterministas.

### Higiene de sesión

`statement_timeout = 5s` e `idle_in_transaction_session_timeout = 15s`, para que ninguna
transacción huérfana retenga locks sobre `tbl_inventario`. Un job de `pg_cron` ejecuta cada minuto
`wms.fn_barrer_operaciones_colgadas()`, que cierra como `FALLIDO` toda operación con más de 5
minutos `EN_PROCESO` (proceso muerto entre fases) y purga las vencidas a 48 h.

## 3.7 Los diez escenarios, respondidos

| # | Escenario | Qué ocurre | Garantía que actúa |
|---|---|---|---|
| 1 | **Doble clic rápido** | Modal: mismo `id_operacion` → la 2.ª recibe `EN_CURSO` (409) o `YA_COMPLETADA` (200 con la respuesta original). Stepper: el debounce las une en una operación, o son dos operaciones legítimas de `+1`. Un solo efecto por operación | `pk_tbl_operaciones` + índice único |
| 2 | **Dos clics separados varios segundos** | Idéntico al anterior. **El intervalo no participa**: lo que decide es si el `id_operacion` es el mismo | Idem |
| 3 | **Conexión muy lenta** | El modal sigue disponible; los reenvíos llevan el mismo id; se aplica una vez | Idem |
| 4 | **El frontend cancela una petición que ya llegó** | El abort no revierte nada si ya confirmó. El reenvío devuelve la respuesta original; si no había confirmado, el `ROLLBACK` dejó todo intacto y el reenvío la aplica | `YA_COMPLETADA` / `FALLIDO` reejecutable |
| 5 | **Timeout en el cliente, backend sí procesó** | El reenvío del mismo id devuelve `YA_COMPLETADA` con el cuerpo original. **No suma otra vez** | `pk_tbl_operaciones` |
| 6 | **El navegador reintenta la petición** | Es byte por byte la misma petición, con el mismo encabezado: se trata como reenvío | Idem |
| 7 | **Dos usuarios simultáneos** | `id_operacion` distintos → ambas se aplican y suman; dos renglones con su usuario, fecha y operación | `UPDATE` acumulativo atómico + bitácora por trigger |
| 8 | **Cómo lo garantiza PostgreSQL** | `ux_tbl_movimientos_inventario__operacion` sobre `(id_operacion, producto_id, almacen_id, tipo_movimiento)`. El trigger escribe la bitácora en la misma transacción que muta la existencia, así que violar ese índice **revierte también la existencia** | Índice único del motor |
| 9 | **`id_operacion` + transacción + rollback/commit** | Reserva confirmada aparte (visible para los concurrentes); mutación y sellado **en la misma transacción**, confirman o fracasan juntos; el fallo deja `FALLIDO`, que es reejecutable con el mismo id | Fases 0/1/2 |
| 10 | **La app falla tras guardar y antes de responder** | El movimiento y el sello ya confirmaron juntos. El cliente reintenta con el mismo id y recibe `YA_COMPLETADA` con la respuesta original. Si el fallo fue **antes** del `COMMIT`, no se aplicó nada y el barrido devuelve la operación a reejecutable | Sellado transaccional + barrido |

## 3.8 Matriz de pruebas

**Unitarias** (xUnit + FluentAssertions + NSubstitute) — U1..U10: parsing de SKU válido e
inválido (`elec-0001`, `ELEC-1`, `ELE-0001`, `ELEC-00001`, `ELEC_0001`), recarga de la regla
activa sin recompilar, delta cero, llave de idempotencia ausente, transiciones ilegales
(`ENVIADA → CANCELADA`, `BORRADOR → ENVIADA`), total con decimales, hash estable ante distinto
orden de propiedades, y el mapeo completo SQLSTATE → HTTP.

**Integración** (Testcontainers.PostgreSql con el esquema real):

| # | Escenario | Aserción |
|---|---|---|
| I0 | Aplicar `0001` + `0002` sobre Postgres limpio | Ejecuta sin error — *valida este documento* |
| I1 | 50 tareas paralelas `+1` sobre la misma fila | `cantidad_fisica = inicial + 50`, exactamente 50 movimientos |
| I2 | Misma llave dos veces | Un solo movimiento, respuesta idéntica |
| I3 | Misma llave, body distinto | 409 |
| I4 | Dos peticiones simultáneas, misma llave | Una 200, otra 409, **un** movimiento |
| I5 | Salidas concurrentes que exceden la existencia | Una OK, otra `WM002`; nunca negativo |
| I6 | Dos órdenes confirmadas en paralelo sobre el último producto | Una `CONFIRMADA`, otra `WM002` |
| I7 | 20 órdenes multi-partida confirmadas en paralelo | Cero deadlocks |
| I8 | 30 altas paralelas en la misma categoría | 30 SKUs distintos y consecutivos |
| I9 | Cancelar orden `CONFIRMADA` | Repone reserva, no toca físico |
| I10 | Enviar orden | Descuenta físico y reserva en el mismo movimiento |
| I11 | `UPDATE` directo sobre la bitácora | `WM006` |
| I12 | Cambiar el SKU de un producto | `WM003` |
| I13 | Borrar una categoría con productos | `23503` |
| I14 | Importar 100 renglones con 7 inválidos | 93 OK, 7 con código, reporte consultable |
| I15 | Suma de `delta_fisica` de la bitácora | Reconstruye `cantidad_fisica` exacta |
| I16 | Confirmar orden de 3 partidas con una llave | 3 movimientos, sin `23505` *(regresión de C1)* |
| I17 | Mover `almacen_id` de orden confirmada | `WM007` *(regresión de C2)* |
| I18 | Alta con consecutivo impuesto y luego alta automática | Ambas funcionan *(regresión de C3)* |
| I19 | Dos ajustes distintos en una transacción | Cada movimiento con su propio contexto *(regresión de A1)* |
| I20 | **Mismo `id_operacion` enviado dos veces en secuencia** | `base + 2`, **un** movimiento; la 2.ª devuelve la respuesta original |
| I21 | **Mismo `id_operacion` enviado dos veces en paralelo** | Una `200`, otra `409/WM013`; **un** movimiento |
| I22 | Mismo `id_operacion` con cuerpo distinto | `409/WM015`; nada aplicado |
| I23 | **Insertar a mano dos movimientos con el mismo `id_operacion` y producto** | `23505` sobre `ux_…__operacion`; la existencia **no** cambia |
| I24 | Abortar la petición mid-`UPDATE` | `57014` → `ROLLBACK`; existencia intacta; llave `CANCELADO` |
| I25 | Matar la conexión durante la transacción | Rollback implícito del servidor; nada aplicado |
| I26 | Comando que falla en su tercera escritura | Las dos primeras revertidas; cero movimientos |
| I27 | Dos **usuarios distintos** ajustan el mismo producto a la vez | Ambos deltas aplicados, **dos** movimientos con su usuario y fecha |
| I28 | Mutar inventario sin usuario en contexto | `WM014`; nada aplicado |
| I29 | Ajuste con un usuario inactivo | `WM014` |
| I30 | Desactivar un usuario con movimientos históricos | Los movimientos siguen resolviendo su nombre; `desactivado_en` y `desactivado_por_usuario_id` sellados |
| I31 | Intentar borrar un usuario con movimientos | `23503` |
| I32 | Llave huérfana `EN_PROCESO` por proceso muerto | El job la cierra como `FALLIDO`; una petición nueva no queda bloqueada |
| I33 | **Dos peticiones se cruzan sobre el mismo producto, 200 iteraciones** | **Cero `40P01`** *(regresión del deadlock)* |
| I34 | Modal: confirmar, esperar 5 s sin respuesta, confirmar de nuevo | `base + 2`, un movimiento *(el escenario del requerimiento)* |
| I35 | Stepper: 3 clics lentos vs. 3 clics rápidos | `base + 3` en ambos casos, con 3 y 1 movimientos respectivamente |
| I36 | Borrar una orden en `BORRADOR` | `WM006` |
| I42 | Operación que falla y se reintenta con el mismo id | La 1.ª deja `FALLIDO`; la 2.ª se ejecuta y aplica una vez |
| I43 | Matar el proceso entre fase 0 y fase 1, luego reintentar | El barrido cierra `FALLIDO`; el reintento aplica una vez |
| I44 | Matar el proceso tras el `COMMIT` y antes de responder | El reintento devuelve `YA_COMPLETADA`; **no** vuelve a aplicar |
| I45 | Abortar la petición 50 ms antes del `COMMIT`, en bucle 100 veces | Cada operación aplica exactamente 0 o 1 vez; nunca 2 |
| I46 | Mutar inventario sin `id_operacion` en contexto | `WM012`; nada aplicado |
| I47 | 20 usuarios, 20 `id_operacion` distintos, mismo producto | Los 20 deltas aplicados, 20 movimientos con su usuario |
| I37 | `TRUNCATE` sobre la bitácora | `WM006` |
| I38 | Reactivar un catálogo desactivado | `desactivado_en` y su autor **sobreviven** |
| I39 | Desactivar sin usuario en contexto | `WM014` |
| I40 | Cancelar una orden en `BORRADOR` | `cancelado_por_usuario_id` queda registrado pese a no haber movimientos |
| I41 | Reintento tras `40P01` | Se reintenta con el **mismo** `id_operacion`; la reserva lo readmite como `NUEVA` |

**Ejecutadas ya** (`db/pruebas/verificar.sh`, PostgreSQL 16): `I0` las tres migraciones aplican
con `ON_ERROR_STOP=1`; `I20` reclic del modal → `23505` y existencia `base+2`; `I21` reintento
accidental rechazado; `I15` `sum(delta_fisica) = cantidad_fisica`; `I22` carga/ruta distinta →
`CARGA_DISTINTA`; `I28`/`I46` mutación sin usuario o sin operación → `WM014`/`WM012`; `I11`
`UPDATE` sobre bitácora → `WM006`; `I37` `TRUNCATE` → `WM006`; `I5` sobreventa → `WM002`;
`I12` SKU inmutable → `WM003`; `I27` dos operadores → dos renglones y suma correcta; `I38`
reactivar conserva el sello; barrido que respeta operaciones con rastro; y el rol `wms_api` con
`INSERT` denegado sobre la bitácora.

**Componentes** (Vitest + Testing Library) — V1: el modal acuña **un** `id_operacion` al abrirse y
lo reenvía idéntico en cada clic de Confirmar. V2: cambiar la cantidad acuña un id nuevo. V3: el
campo de cantidad se congela mientras hay operación en vuelo, **el botón no**. V4: el stepper
acumula la intención sin emitir una petición por clic. V5: `AbortController` aborta la petición en
vuelo sin marcar la operación como fallida en el cliente. V6: una respuesta de operación no vigente
se ignora. V7: reversión ante 409/422 con toast. V8: los cinco estados visibles. V9: estado vacío.
V10: skeleton. V11: combobox alimentado del catálogo.

**E2E** (Playwright) — E1: ciclo completo categoría → almacén → producto → inventario → orden →
confirmar → enviar → movimientos → dashboard. E2: descargar plantilla → importar con errores →
consultar resultado. **E3:** con la red estrangulada a 5 s, confirmar el modal de `+2` tres veces;
la existencia sube exactamente 2 y la bitácora muestra **un** movimiento. **E4:** dos pestañas con
operadores distintos ajustan el mismo producto simultáneamente; ambas cantidades se aplican y la
bitácora muestra **dos** renglones con su usuario, hora y `id_operacion`.

### Lo que se ejecuta hoy, con sus cifras

| Suite | Cómo se corre | Resultado |
|---|---|---|
| Unitarias .NET | `dotnet test tests/Wms.UnitTests` | **83 pruebas, 0 fallos** |
| Motor / PL-pgSQL | `bash db/pruebas/verificar.sh` | **5 suites, 58 aserciones, 0 fallos** |
| API extremo a extremo | `bash tests/verificar_api.sh` | **279 aserciones, 0 fallos** |
| Componentes web | `npm test` en `web/` | **5 archivos, 47 pruebas, 0 fallos** |
| Navegador | `npm run e2e` en `web/` (Playwright) | **10 escenarios, 0 fallos** |

Las cinco se ejecutan sobre PostgreSQL 16 y .NET 8 reales dentro de contenedores desechables; no
hay dobles ni motores en memoria. `verificar_api.sh` levanta Postgres + migraciones + semilla + la
API y ejerce los endpoints con `curl`, que es la única forma de cerrar reintento tras *timeout*,
latencia real y cancelación del cliente a mitad de transacción.

Cubierto en esta ronda, sobre la API real: 25 por página en inventario, movimientos, órdenes y
catálogos; el total del conjunto filtrado; la navegación entre páginas; los filtros que sobreviven
al cambio de página y el total que cambia al cambiar el filtro; la exportación que devuelve las 92
filas filtradas y no las 25 visibles; el alta de catálogo permitida al operador 1 y rechazada con
403 para cualquier otro, en las cinco entidades; el `INSERT` directo contra la base con otro
operador rechazado con `WM020`; y la importación, que ya no sirve como vía de escape.

Los escenarios de navegador corren contra la pila real levantada con `docker compose up -d`:
nginx sirviendo el bundle compilado y proxyando a la API. E1 recorre el ciclo completo; E2 la
importación con errores y la reimportación que no duplica; E3 el modal bajo latencia y el stepper;
E4 dos pestañas con operadores distintos sobre el mismo producto; E5 los permisos de catálogo,
incluida una llamada directa al endpoint saltándose la interfaz.

## 3.9 Docker y datos iniciales

El pipeline de migración usa **`psql -v ON_ERROR_STOP=1 --single-transaction`**. Sin
`ON_ERROR_STOP`, `psql` imprime los errores y aun así **sale con código 0** — fue exactamente la
razón por la que un archivo que no compilaba llegó a darse por bueno durante dos rondas de revisión.

`docker compose up` levanta: `db` (postgres:16-alpine con volumen y healthcheck), `migrador`
(aplica `db/migraciones/*.sql` en orden y luego `db/semilla.sql`, `depends_on: db healthy`), `api`
(.NET 8, `depends_on: migrador completed_successfully`, puerto 8080) y `web` (Vite → nginx, puerto
5173, proxy `/api`). Perfil `supabase`: la API apunta a la cadena de Supabase y se omite `db`.

Semilla: **5 operadores** (`USR-0001` = `SISTEMA`, más 4 con rol `OPERADOR`/`SUPERVISOR`, uno de
ellos **inactivo** para poder demostrar que la trazabilidad sobrevive al soft-delete), 6 categorías,
3 almacenes, 40 productos, inventario poblado en los 3 almacenes, 8 clientes, 10 órdenes
(3 `BORRADOR`, 3 `CONFIRMADA`, 3 `ENVIADA`, 1 `CANCELADA`) y ~200 movimientos **con fechas
escalonadas y repartidos entre los operadores**, para que la serie temporal del dashboard y
`vw_aportacion_por_usuario` tengan datos reales en lugar de un único pico en el arranque.

La semilla abre fijando el contexto de sesión —usuario `1` (`SISTEMA`)— y acuña un
`id_operacion` por lote sembrado. Sin usuario el trigger aborta con `WM014`; sin `id_operacion`,
con `WM012`. Ambos son el comportamiento deseado: **ningún movimiento sin autor ni sin operación**.

---

## 3.10 Paginación de listados

**Tamaño convenido: 25 por página**, en todos los listados. El recorte lo hace el motor con
`limit`/`offset`; la API nunca trae el conjunto completo para quedarse con 25.

El total viaja con los elementos —`count(*) over()` en la **misma** consulta— porque la interfaz
muestra «X–Y de N». Dos consultas separadas pueden ver estados distintos de la tabla y devolver un
total que no corresponde a las filas entregadas.

Se usa `limit`/`offset` y no keyset: «página 37 de 50» exige saltar a una posición arbitraria, que
es justo lo que el keyset no permite. El precio es que el offset profundo se degrada; con los
volúmenes de este sistema no compensa el cambio, y queda escrito para que sea una decisión y no un
descuido.

La envoltura es única para todos los listados:

```json
{ "elementos": [ … ], "total": 137, "numeroPagina": 3, "porPagina": 25,
  "totalPaginas": 6, "hayAnterior": true, "haySiguiente": true }
```

**Los filtros sobreviven al cambio de página, y cambiar un filtro devuelve a la página 1.** Sin lo
segundo, estar en la página 7 y aplicar un filtro que sólo tiene 2 páginas produce una lista vacía
sin explicación. La comparación se hace sobre la clave serializada de los filtros, no filtro por
filtro.

**La exportación no se pagina.** El botón manda los mismos filtros de la pantalla y ningún
parámetro de página: el archivo trae el conjunto filtrado completo, no los 25 visibles. El CSV se
escribe directo al flujo de respuesta conforme el motor entrega las filas, así que exportar 50 000
renglones no obliga a la API ni al navegador a materializarlos.

**Techos declarados.** Los listados no recortan en silencio:

- `porPagina` se acota a 200. Pedir más devuelve 200, no la tabla entera.
- `GET /api/catalogos/{recurso}` sin `porPagina` sirve hasta ese techo, porque los combos de la
  interfaz quieren el catálogo entero y no una página. Un catálogo con más de 200 registros
  llegaría recortado a los combos; con los volúmenes de este sistema no se alcanza, y la pantalla
  de Catálogos —que sí puede crecer— pide sus 25 explícitamente.
- `POST /api/importacion` devuelve el detalle completo del archivo recién procesado: es la
  respuesta a lo que el usuario acaba de subir, y su tamaño lo eligió él. El resultado
  **persistido** (`GET /api/importacion/{id}`) sí va paginado.

## 3.11 Quién puede dar de alta en un catálogo

**Sólo el operador 1 (SISTEMA).** La regla vive en el motor, en un trigger `BEFORE INSERT`
aplicado a **todas** las tablas `cat_%` —presentes y futuras— por un bloque que las recorre y
después comprueba su propia cobertura: si alguna quedara sin trigger, la migración falla en vez de
dejar un hueco.

El trigger lee `wms.ctx_usuario_id`, la variable de sesión que toda mutación fija dentro de su
propia transacción. Que la restricción esté ahí y no en la API es lo que cierra las tres vías de
escape:

1. **Llamar al endpoint con otro operador.** La API responde 403 antes de validar el cuerpo —para
   que un operador sin permiso reciba «no puedes», no «te falta un campo»—, y si esa comprobación
   se cayera, el motor lo detendría igual con `WM020`.
2. **Un alta genérica.** `POST /api/catalogos/{recurso}` no refleja las columnas de la tabla:
   trabaja sobre una lista blanca explícita por catálogo. El SKU acuñado, los consecutivos y los
   sellos de baja no se pueden capturar, porque los calcula el motor.
3. **La importación masiva.** Era la vía real de escape: crea productos, y un producto es un
   registro de catálogo. Hoy el trigger la alcanza igual, y el renglón se marca con
   `PERMISO_ALTA_CATALOGO` en vez de tumbar el lote entero.

Ocultar el botón «Nuevo» en el frontend es cortesía, no seguridad: quien no puede usarlo no lo ve,
y quien llame por otra vía recibe el mismo rechazo.

### Inconsistencia documentada: el alta está más restringida que la baja

Dar de alta en un catálogo exige ser el operador 1. **Darlo de baja sólo exige estar
identificado**: `fn_sellar_baja_logica` pide un operador, cualquiera, y sella `desactivado_en` y
`desactivado_por_usuario_id`.

No se ha igualado, y es deliberado. Igualarlas es un cambio de política, no una corrección: el
enunciado del usuario habla del **alta**, y endurecer la baja por simetría cambiaría el
comportamiento de pantallas que hoy funcionan sin que nadie lo haya pedido. Las dos operaciones
tampoco son el mismo riesgo —el alta introduce identificadores nuevos que otras filas empezarán a
referenciar; la baja es reversible y queda auditada con fecha y autor—, así que la asimetría es
defendible además de intencional.

Queda anotada aquí para que sea una decisión visible. Si se quiere simetría, el cambio es de una
línea en `fn_sellar_baja_logica` y de una condición en el frontend.

La desactivación de **movimientos** sí está reservada al operador 1, exigida en
`fn_revertir_movimiento`. Es un caso distinto: la bitácora es de sólo inserción y «desactivar» un
movimiento asienta una `REVERSA`, no borra nada.


## 3.12 Corregir y dar de baja un catálogo

**Editar no exige ser el operador 1.** Se implementó la política que el motor ya imponía,
no una nueva por simetría: `fn_sellar_baja_logica` pide un operador identificado, cualquiera,
y lo mismo vale para una corrección. La asimetría con el alta está en §3.11.

Lo que sí se endureció, porque la revisión encontró un agujero real:

### El rol de un operador no lo cambia cualquiera

`PermisoExportacion` autoriza la exportación por **rol** (SUPERVISOR y SISTEMA). Si la
edición de catálogos dejara escribir `cat_usuarios.rol` libremente, un OPERADOR podría
ascenderse a SUPERVISOR y concederse a sí mismo la exportación —que incluye precios y
valuación— sin pasar por nadie. Es una escalada de privilegios por la puerta de atrás.

El rol queda reservado al operador 1, exigido en el motor (`WM021`, migración `0007`). El
rol del propio operador 1 es fijo incluso para él: degradarlo tendría el mismo efecto que
desactivarlo.

### El operador SISTEMA no se puede desactivar

Es el único autorizado a dar de alta en catálogos, y `fn_ajustar_existencia` rechaza a los
operadores inactivos. Darlo de baja dejaría el sistema sin nadie capaz de crear un catálogo
y sin forma de deshacerlo desde la propia aplicación. Se bloquea con `WM022`.

### Concurrencia optimista en los cinco catálogos

`cat_productos` y `tbl_ordenes` ya llevaban `version_concurrencia`; usuarios, categorías,
almacenes y clientes sólo tenían `actualizado_en`. Sin una versión, dos operadores
corrigiendo el mismo cliente producen «el último gana» en silencio, que es justo lo que el
resto del sistema evita. La migración `0007` lo uniforma.

La versión es **obligatoria** en el `PUT`: sin ella la edición sería ese mismo «último
gana». Cero filas actualizadas se diagnostica antes de responder, porque «no existe» (404) y
«alguien más lo modificó» (409/`WM008`) no dan el mismo consejo al usuario.

### Qué se puede corregir y qué no

La lista es explícita por catálogo, igual que la del alta, y una prueba comprueba que
`Editables ⊆ Obligatorios ∪ Opcionales`: editar no puede abrir columnas que el alta ni
siquiera ofrece.

| Catálogo | Se corrige | No se corrige, y por qué |
|---|---|---|
| Categorías | `codigo`, `nombre`, `descripcion` | `consecutivo_sku` lo lleva el motor. El `codigo` sí se corrige **mientras no haya acuñado ningún producto**; en cuanto existe uno, la FK `sku_prefijo → codigo` (`on update restrict`) lo congela — la regla la decide el motor, no la API |
| Almacenes | `codigo`, `nombre`, `direccion` | — el código es un localizador, no forma parte del SKU y nada lo referencia por valor |
| Clientes | `nombre`, `correo`, `telefono` | `codigo` es generado y opaco: no incorpora el nombre comercial, que sí cambia |
| Operadores | `nombre`, `correo`, `rol`\* | `codigo` es generado. \*El rol sólo lo cambia el operador 1 |
| Productos | `categoria_id`, `nombre`, `descripcion`, `precio_unitario` | `sku`, `sku_prefijo` y `sku_consecutivo` están congelados (`WM003`). Recategorizar **no** reescribe el SKU: para eso se congeló |

En todos: `es_activo` / `estatus` tienen su propio endpoint, y los sellos de baja y la
versión de concurrencia los calcula el motor.

### La baja no borra

`fn_sellar_baja_logica` estampa `desactivado_en` y `desactivado_por_usuario_id` dentro de la
misma transacción, leyendo el operador del contexto de sesión. Reactivar **no** limpia ese
sello: la baja ocurrió y su rastro debe sobrevivir; el `CHECK` es unidireccional justamente
para permitirlo. Pedir una vigencia que el registro ya tiene devuelve `WM023` en vez de
fingir que hizo algo, y la lectura previa toma el candado de fila para que dos operadores no
crean ambos haber sido ellos.

# 4. Manejo de errores y concurrencia

Resumen de cómo el sistema garantiza que ninguna operación quede incompleta y que los movimientos
de múltiples usuarios sean consistentes y auditables.

## Ninguna operación queda a medias

Toda escritura vive dentro de una transacción abierta por el `TransactionBehavior` de MediatR. El
`try/catch` que la envuelve solo confirma cuando **todas** las operaciones relacionadas
terminaron bien; ante cualquier excepción —validación, fallo de una tabla intermedia, pérdida de
conexión, cancelación del cliente— ejecuta `ROLLBACK` y el estado vuelve exactamente a como estaba.
Si una operación toca tres tablas y falla la tercera, las dos primeras se revierten.

Tres capas independientes sostienen la garantía:

1. **La transacción** revierte el trabajo de la aplicación.
2. **Las restricciones del motor** (`cantidad_fisica >= 0`, `cantidad_reservada <= cantidad_fisica`,
   la aritmética de la bitácora) rechazan cualquier estado imposible, venga por donde venga —
   incluido un `UPDATE` manual que se saltara la API.
3. **Los triggers** garantizan invariantes que ninguna ruta de código puede evadir: toda mutación
   de existencia deja movimiento, el movimiento es inmutable, el SKU no se reasigna, la orden no
   salta estados.

Cuando el cliente cancela, `HttpContext.RequestAborted` propaga el token hasta Npgsql, la sentencia
en vuelo aborta con `57014` y el `catch` hace `ROLLBACK`: **nada se aplicó**. La única ventana
irreducible es el instante en que el `COMMIT` ya salió — PostgreSQL no aborta un commit en curso.
El sistema no la ignora ni finge que no existe: el cliente nunca asume que abortar equivale a no
aplicar, y el protocolo de supersesión consulta el estatus real de la petición anterior y
**compensa** si resulta que sí confirmó.

## Los movimientos de varios usuarios son consistentes

`cantidad_final = base + u₁ + u₂ + …` se cumple **acumulando movimientos individuales**, nunca
sobrescribiendo un total. Cada petición aplica su delta con un `UPDATE` de una sola sentencia
(`SET cantidad = cantidad + delta`), que toma el row lock y re-evalúa la fila tras esperar su turno:
no hay lectura previa que pueda quedar obsoleta, luego **no hay lost update**. Cada uno de esos
`UPDATE` dispara el trigger que escribe **un renglón propio** en la bitácora con su usuario, su
fecha, su UUID, su tipo y las cantidades antes y después.

| Riesgo que pediste evitar | Mecanismo que lo cierra |
|---|---|
| Pérdida de movimientos | `UPDATE` acumulativo atómico + un renglón de bitácora por mutación, garantizado por trigger |
| Sobrescritura de movimientos anteriores | El cliente envía **deltas**, jamás cantidades absolutas calculadas sobre una lectura vieja |
| Duplicación accidental | **Dos barreras**: `pk_tbl_operaciones` por intención (primer filtro, respuesta original en el reenvío) y `ux_tbl_movimientos_inventario__operacion` en el motor (barrera ineludible, verificada por ejecución) |
| Cantidades incorrectas | `CHECK` de no negatividad y de cobertura de reserva, más la aritmética verificada de la bitácora |
| Condiciones de carrera | Row locks explícitos, guardias en el `WHERE` del `UPDATE` y `ORDER BY producto_id` en los bucles de orden. La reserva de la operación vive fuera de la transacción de trabajo, así que no hay dos clases de recurso tomadas en órdenes opuestos — el `40P01` que la auditoría reprodujo en el diseño anterior desaparece con el protocolo que lo causaba |
| Datos parcialmente guardados | Una transacción por comando, con `ROLLBACK` en `catch` y `COMMIT` solo al final |

Los **reenvíos** de una misma operación —doble clic sobre el modal, reintento por timeout,
reintento del navegador— se reconocen por su `id_operacion` y **no vuelven a aplicar nada**: se
devuelve la respuesta original. Las operaciones de usuarios **distintos** tienen `id_operacion`
distintos y todas se contabilizan.

Esa garantía **no depende de ninguna ventana de tiempo**. El `debounce` y el `AbortController` del
frontend son optimización y UX; si ambos fallaran, el resultado seguiría siendo correcto, porque
`ux_tbl_movimientos_inventario__operacion` hace imposible que la misma operación produzca dos
movimientos, y el trigger que escribe la bitácora vive en la misma transacción que muta la
existencia — de modo que violar ese índice revierte también la existencia.

## La historia siempre se puede reconstruir

Ningún registro se borra. Las bajas son lógicas y quedan selladas con `desactivado_en` y
`desactivado_por_usuario_id`. Todas las llaves foráneas que atraviesan información histórica son
`RESTRICT`, así que un producto, almacén, cliente o usuario desactivado **sigue siendo resoluble**
desde cualquier movimiento pasado. La bitácora es de solo inserción y su estado se deriva en
lectura en vez de almacenarse mutable.

La suma de `delta_fisica` de la bitácora reconstruye `cantidad_fisica` exactamente — la prueba
`I15` lo verifica —, y `vw_aportacion_por_usuario` responde en una consulta qué aportó cada
operador sobre cada producto y cuándo.

Cada renglón conserva, incluso después de que su producto, almacén o usuario se desactiven:
`uuid_movimiento`, `id_operacion`, `producto_id`, `almacen_id`, `usuario_id`, `creado_en`,
`tipo_movimiento`, los deltas con su estado antes y después, y la referencia tipada a la orden o
al lote que lo originó.

---

# 5. Fuera de alcance (declarado)

Autenticación y RLS · multimoneda · lotes y caducidad (FEFO) · kits y listas de materiales ·
devoluciones y notas de crédito · órdenes multi-almacén · ubicaciones dentro del almacén
(pasillo/rack/nivel) · reabastecimiento automático.

Los tres primeros tienen punto de extensión previsto: multimoneda añadiría `moneda` a
`tbl_ordenes` y `cat_productos`; los lotes convertirían la PK de `tbl_inventario` en una tripleta
`(producto_id, almacen_id, lote)`; los kits serían `cat_productos.tipo_articulo` más una tabla
`rel_kit_componente`. Ninguno requeriría rehacer el modelo.
