# 002 · Convención de nombres, modelo relacional y primera auditoría

**Periodo:** 2026-08-21 23:19:39 UTC → 2026-08-21 23:53:16 UTC

**Intervenciones en este archivo:** 1 del usuario, 9 de Claude, 1 del sistema.

---

### [USUARIO] · 2026-08-21 23:19:39 UTC

Quiero que continúes con el diseño y documentación de la solución, pero antes necesito establecer una convención clara y consistente para el esquema de la base de datos.

### Convención de nombres para tablas

Todas las tablas de la base de datos deben utilizar prefijos según su propósito:

* `cat_` → Tablas de **catálogos** o información de referencia relativamente estática.

  * Ejemplo: `cat_productos`, `cat_categorias`, `cat_estados`.
* `tbl_` → Tablas que contienen la **data operativa o transaccional real del sistema**.

  * Ejemplo: `tbl_ordenes`, `tbl_movimientos`, `tbl_usuarios`.
* `rel_` → Tablas cuya finalidad principal sea representar una **relación entre dos o más entidades**, especialmente relaciones muchos-a-muchos.

  * Ejemplo: `rel_producto_categoria`, `rel_orden_producto`.

### Reglas importantes

1. Revisa todo el esquema de base de datos propuesto hasta este momento.
2. Clasifica cada tabla de acuerdo con su propósito y aplica el prefijo correspondiente.
3. Si alguna tabla no encaja claramente en `cat_`, `tbl_` o `rel_`, no inventes un nuevo prefijo. Señala el caso y explica qué clasificación recomiendas.
4. Mantén una nomenclatura consistente para nombres de tablas, columnas, llaves primarias, llaves foráneas e índices.
5. No utilices nombres de productos, nombres comerciales o información que pueda cambiar como parte de identificadores estructurales.
6. Considera que esta convención tiene como objetivo que, al visualizar la base de datos, sea posible identificar rápidamente qué tipo de información contiene cada tabla.
7. Si detectas inconsistencias o redundancias en el modelo actual, señálalas antes de asumir que el diseño existente es correcto.
8. No cambies la lógica funcional del sistema únicamente por aplicar los prefijos. Si un cambio estructural es necesario, justifícalo.

### Después de actualizar la base de datos

Una vez aplicada y validada esta estructura de nombres, **continúa con la elaboración del documento de especificación** que estamos construyendo.

El documento debe reflejar la estructura actualizada de la base de datos, por lo que cualquier tabla, relación, entidad o referencia mencionada en la especificación debe utilizar los nombres definitivos con sus respectivos prefijos.

Quiero que el resultado final siga este orden:

1. **Esquema actualizado de la base de datos**

   * Tablas.
   * Propósito de cada tabla.
   * Relaciones.
   * Llaves primarias y foráneas.
   * Convenciones utilizadas.

2. **Observaciones y decisiones de diseño**

   * Cambios realizados.
   * Decisiones relevantes.
   * Posibles ambigüedades o puntos que requieran confirmación.

3. **Documento de especificación**

   * Continúa con la estructura y contenido que ya veníamos desarrollando.
   * Integra la nueva nomenclatura de base de datos.
   * No reinicies el documento desde cero si ya existe contenido previo; continúa a partir del punto en el que nos quedamos.

Antes de continuar con la especificación, asegúrate de que el esquema de base de datos y su nomenclatura sean coherentes entre sí.

---

### [CLAUDE] · 2026-08-21 23:22:09 UTC

Antes de continuar: la convención toca **todas** las entidades ya diseñadas, así que voy a materializar el esquema renombrado en un archivo, someterlo a auditoría adversarial multi-lente y solo entonces escribir la especificación. Arranco.

---

‹ 2 operaciones de herramienta: Write×2 ›

### [CLAUDE] · 2026-08-21 23:24:29 UTC

Esquema renombrado y materializado. Ahora lo someto a auditoría adversarial con cinco lentes independientes antes de darlo por bueno.

---

‹ 1 operaciones de herramienta: Workflow×1 ›

### [CLAUDE] · 2026-08-21 23:26:02 UTC

Mientras la auditoría corre, adelanto las secciones del spec que no dependen del veredicto del esquema.

---

‹ 1 operaciones de herramienta: Write×1 ›

### [CLAUDE] · 2026-08-21 23:27:28 UTC

## [💻 AGENTE DB-DBA] — Clasificación aplicada (preliminar, pendiente de auditoría)

Antes de exponer el resultado necesito declarar el **discriminador** que usé, porque sin él la clasificación sería arbitraria caso por caso — y tú pediste consistencia, no criterio ad-hoc:

> **`rel_` cuando la fila no tiene ciclo de vida propio**: existe solo como componente de una de sus entidades padre y muere con ella (`ON DELETE CASCADE`). Su identidad *es* el par que vincula.
> **`tbl_` cuando la fila sobrevive a las transacciones que la tocan**: tiene estado propio, nunca se cascadea, y otras entidades se le restringen (`ON DELETE RESTRICT`).
> **`cat_` cuando la fila es dato de referencia**: se lee mucho, se escribe poco, y su borrado está restringido por definición.

| # | Nombre anterior | Nombre definitivo | Prefijo | Propósito |
|---|---|---|---|---|
| 1 | `categories` | `cat_categorias` | `cat_` | Catálogo de categorías + contador de acuñación de SKU |
| 2 | `warehouses` | `cat_almacenes` | `cat_` | Catálogo de almacenes con código de longitud fija |
| 3 | `products` | `cat_productos` | `cat_` | Catálogo de productos con SKU acuñado e inmutable |
| 4 | `customers` | `cat_clientes` | `cat_` | Catálogo de clientes |
| 5 | `sku_format_rules` | `cat_reglas_sku` | `cat_` | Reglas Regex dinámicas del SKU |
| 6 | `inventory` | **`tbl_inventario`** | `tbl_` | ⚠️ **Caso señalado** — existencias por producto/almacén |
| 7 | `inventory_movements` | `tbl_movimientos_inventario` | `tbl_` | Bitácora append-only de movimientos |
| 8 | `orders` | `tbl_ordenes` | `tbl_` | Órdenes de venta |
| 9 | `order_items` | **`rel_orden_producto`** | `rel_` | Partidas: relación orden↔producto con atributos |
| 10 | `idempotency_keys` | **`tbl_llaves_idempotencia`** | `tbl_` | ⚠️ **Caso señalado** — infraestructura, no dato de negocio |
| 11 | `import_batches` | `tbl_importacion_lotes` | `tbl_` | Lotes de carga masiva |
| 12 | `import_batch_rows` | `tbl_importacion_renglones` | `tbl_` | Resultado por renglón importado |

### ⚠️ Regla 3 — casos que no encajan limpiamente

**`tbl_inventario` (el caso importante).** Formalmente *parece* `rel_`: su PK es `(producto_id, almacen_id)`, dos FKs y nada más. Pero clasificarla como `rel_` sería **activamente engañoso** frente a tu objetivo de la regla 6: le diría a quien abra la base "esto es una tabla puente, sigue de largo", cuando en realidad es **la tabla más volátil y más crítica de todo el sistema** — es donde vive el estado que la concurrencia puede corromper. Su forma N:M es incidental; su propósito es custodiar existencias. **Recomiendo `tbl_`.**

**`tbl_llaves_idempotencia`.** No es catálogo, no es dato de negocio, y no relaciona entidades: es infraestructura de protocolo HTTP con TTL de 48 h. Ninguno de los tres prefijos le queda natural. Como prohibiste inventar un cuarto, **`tbl_` es la menos mala** (una fila por operación de API = transaccional). **Lo señalo para tu ratificación.**

**`cat_reglas_sku`.** Es configuración, no catálogo de negocio. Encaja en tu definición de `cat_` ("información de referencia relativamente estática"), así que **`cat_` sin conflicto** — solo lo anoto para que no sorprenda verla junto a productos y clientes.

**`rel_orden_producto`.** Coincide con tu propio ejemplo. Nota: **no es una tabla puente pura** — carga `cantidad`, `precio_unitario` congelado e `importe_linea`. Es una *entidad asociativa*, que es el caso de libro de `rel_` y por eso lo acepto sin objeción.

### Extensión de la convención a objetos que no son tablas

Tu convención cubre tablas. Para no dejar el resto sin regla, la extendí — **sin inventar prefijos de tabla**, que es lo que prohibiste: `pk_` `uq_` `fk_` `ck_` para constraints, `ix_`/`ux_` para índices, `trg_` triggers, `fn_` funciones, `vw_` vistas, `seq_` secuencias. Columnas en español snake_case, sufijo `_en` para todo `timestamptz`, prefijo `es_` para todo `boolean`.

---

🔄 **Auditoría en curso** (`auditoria-esquema-wms`): 5 auditores independientes — nomenclatura, integridad relacional, concurrencia, semántica PostgreSQL y cobertura de requerimientos — más refutación adversarial de cada hallazgo grave. Te entrego el esquema consolidado, las observaciones de diseño y el documento de especificación en cuanto cierre.

---

### [SISTEMA — notificación de tarea en segundo plano] · 2026-08-21 23:42:03 UTC

<task-notification>
<task-id>whd6gxgcf</task-id>
<tool-use-id>toolu_01MbUcBXwfqjXVYxweTJ7Mmu</tool-use-id>
<output-file>C:\Users\PEDROH~1\AppData\Local\Temp\claude\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\tasks\whd6gxgcf.output</output-file>
<status>completed</status>
<summary>Dynamic workflow "Audita el esquema PostgreSQL renombrado del Mini WMS con 5 lentes independientes y verifica cada hallazgo adversarialmente" completed</summary>
<result>{"total":23,"confirmados":17,"sintesis":"INFORME DE AUDITORIA — ESQUEMA MINI WMS + ORDENES\nBase auditada: esquema_draft.sql (316 lineas) y logica_draft.sql (361 lineas). Estado: DRAFT no desplegado.\n16 hallazgos confirmados de entrada -&gt; 13 tras fusion. 3 CRITICOS, 1 ALTO, 7 MEDIOS, 2 BAJOS.\n\nFUSIONES APLICADAS\n- C1 fusiona 3 hallazgos que describen el mismo defecto desde lentes distintos (integridad / concurrencia / postgres): \"Unicidad de mas: ux_tbl_movimientos__idempotencia\", \"El indice unico de idempotencia rompe toda confirmacion/envio multi-linea\" y \"El indice unico de idempotencia aborta toda orden multilinea (falla dura reproducida)\".\n- C2 fusiona \"Sin llave compuesta orden-almacen: la reserva se desincroniza\" (ALTA, integridad) con \"Orden ENVIADA sin descontar inventario y reserva huerfana permanente\" (CRITICA, postgres): misma causa raiz doble (cabecera mutable + loop sin IF NOT FOUND). Se eleva a CRITICA.\n- A1 fusiona \"El contexto de la bitacora es TRANSACCIONAL, no por operacion\" (MEDIA, concurrencia) con \"El contexto GUC sobrevive al resto de la transaccion y falsifica la bitacora\" (ALTA, postgres). Se conserva ALTA.\n- B1 conserva la severidad degradada por el verificador (de ALTA a BAJA/COSMETICA) y descarta hash_peticion como objeto ofensor.\n\n=====================================================================\nSEVERIDAD CRITICA\n=====================================================================\n\n---------------------------------------------------------------------\nC1. ux_tbl_movimientos__idempotencia declara 1:1 lo que en realidad es 1:N\n---------------------------------------------------------------------\nOBJETO: wms.tbl_movimientos_inventario.llave_idempotencia / ux_tbl_movimientos__idempotencia\n        (esquema_draft.sql:297-298) alimentado por trg_tbl_inventario__bitacora\n        (logica_draft.sql:114-116) via wms.ctx_llave_idem.\n\nQUE ROMPE: una peticion genera N renglones de bitacora (uno por partida) con la misma\nllave, de modo que toda orden de 2+ partidas es inconfirmable, inenviable e incancelable\ncon 23505 en cuanto .NET manda X-Idempotency-Key, que es el flujo obligatorio de D4.\n\nSQL:\n\n    -- 1) Eliminar la unicidad global que confunde 'una llave' con 'un movimiento'.\n    drop index wms.ux_tbl_movimientos__idempotencia;\n\n    -- 2) La llave sigue siendo consultable/trazable, sin imponer unicidad.\n    create index ix_tbl_movimientos__idempotencia\n      on wms.tbl_movimientos_inventario (llave_idempotencia)\n      where llave_idempotencia is not null;\n\n    -- 3) Blindaje real contra doble contabilizacion en el flujo de ordenes.\n    --    Se limita a origen_tipo='ORDEN' porque uq_rel_orden_producto__orden_producto\n    --    garantiza productos distintos por orden; en IMPORTACION un mismo lote SI puede\n    --    ajustar dos veces el mismo par producto/almacen de forma legitima.\n    create unique index ux_tbl_movimientos__idem_orden\n      on wms.tbl_movimientos_inventario\n         (llave_idempotencia, producto_id, almacen_id, tipo_movimiento)\n      where llave_idempotencia is not null and origen_tipo = 'ORDEN';\n\n    -- 4) NO se agrega FK hacia wms.tbl_llaves_idempotencia (llave).\n    comment on column wms.tbl_movimientos_inventario.llave_idempotencia is\n      'Referencia documental (sin FK) a wms.tbl_llaves_idempotencia.llave. Sin FK por diseno: la bitacora es permanente y las llaves se purgan a las 48h (expira_en); ademas trg_tbl_movimientos__inmutable aborta cualquier UPDATE que una accion referencial (on delete set null) requeriria, dejando el purgado imposible.';\n\n    comment on index wms.ux_tbl_movimientos__idem_orden is\n      'Idempotencia a nivel renglon de bitacora para el ciclo de orden: una peticion produce N movimientos, uno por par producto-almacen y tipo. Bloquea el replay exacto sin impedir ordenes multi-partida.';\n\nCAMBIO EN .NET (D4): la unicidad de la PETICION completa vive en wms.tbl_llaves_idempotencia\n(pk sobre llave). .NET debe insertar la llave en EN_PROCESO dentro de la MISMA transaccion\nque invoca fn_confirmar_orden / fn_enviar_orden / fn_cancelar_orden y, ante 23505 sobre\npk_tbl_llaves_idempotencia, devolver codigo_respuesta/cuerpo_respuesta cacheados (409 si\nsigue EN_PROCESO), en lugar de dejar escapar un 23505 desde el trigger de bitacora.\n\n---------------------------------------------------------------------\nC2. Orden ENVIADA sin descontar inventario y reserva huerfana permanente\n---------------------------------------------------------------------\nOBJETO: wms.fn_enviar_orden (logica_draft.sql:278-286, loop sin IF NOT FOUND),\n        wms.fn_cancelar_orden (logica_draft.sql:307-314, mismo hueco) y ausencia de\n        proteccion sobre wms.tbl_ordenes.almacen_id / cliente_id\n        (trg_tbl_ordenes__transicion es BEFORE UPDATE **OF estatus**, logica_draft.sql:180).\n\nQUE ROMPE: un `update wms.tbl_ordenes set almacen_id = 3 where id = 2` sobre una orden ya\nCONFIRMADA pasa sin obstaculo, y fn_enviar_orden actualiza 0 filas en silencio, marca la\norden ENVIADA (terminal), no emite ningun movimiento EMBARQUE y deja la reserva viva para\nsiempre en el almacen original, mermando cantidad_disponible sin forma de liberarla.\n\nSQL:\n\n    -- (a) Cerrar el no-op silencioso del embarque: misma guarda que fn_confirmar_orden.\n    create or replace function wms.fn_enviar_orden(\n      p_orden_id bigint, p_llave_idem text default null, p_actor text default 'sistema')\n    returns wms.tbl_ordenes language plpgsql as $$\n    declare v_orden wms.tbl_ordenes; r record;\n    begin\n      select * into strict v_orden from wms.tbl_ordenes where id = p_orden_id for update;\n      if v_orden.estatus &lt;&gt; 'CONFIRMADA' then\n         raise exception 'WMS_TRANSICION_INVALIDA: orden en %', v_orden.estatus using errcode = '23514';\n      end if;\n\n      perform wms.fn_fijar_contexto_movimiento(\n        'EMBARQUE', 'ORDEN', p_orden_id, null, p_llave_idem, 'Embarque de orden', p_actor);\n\n      for r in select producto_id, cantidad from wms.rel_orden_producto\n                where orden_id = p_orden_id order by producto_id\n      loop\n         update wms.tbl_inventario\n            set cantidad_fisica    = cantidad_fisica    - r.cantidad,\n                cantidad_reservada = cantidad_reservada - r.cantidad,\n                version_ecc = version_ecc + 1, actualizado_en = now()\n          where producto_id = r.producto_id and almacen_id = v_orden.almacen_id;\n         if not found then\n            raise exception 'WMS_SIN_INVENTARIO: producto % en almacen %',\n              r.producto_id, v_orden.almacen_id using errcode = '23514';\n         end if;\n      end loop;\n\n      update wms.tbl_ordenes set estatus = 'ENVIADA', enviado_en = now()\n       where id = p_orden_id returning * into v_orden;\n      return v_orden;\n    end $$;\n\n    -- (a2) Mismo endurecimiento en la liberacion, para que una cancelacion sin fila\n    --      destino aborte en vez de cancelar sin liberar. Dentro del loop de\n    --      fn_cancelar_orden, tras el update de tbl_inventario, insertar:\n    --         if not found then\n    --            raise exception 'WMS_SIN_INVENTARIO: producto % en almacen %',\n    --              r.producto_id, v_orden.almacen_id using errcode = '23514';\n    --         end if;\n\n    -- (b) Congelar el encabezado fuera de BORRADOR (analogo de trg_rel_orden_producto__solo_borrador).\n    create or replace function wms.fn_bloquear_encabezado_no_borrador()\n    returns trigger language plpgsql as $$\n    begin\n      if old.estatus &lt;&gt; 'BORRADOR'\n         and (new.almacen_id is distinct from old.almacen_id\n           or new.cliente_id is distinct from old.cliente_id) then\n         raise exception 'WMS_ORDEN_NO_EDITABLE: almacen y cliente son inmutables en estatus %',\n           old.estatus using errcode = '23514';\n      end if;\n      return new;\n    end $$;\n\n    create trigger trg_tbl_ordenes__encabezado_inmutable\n    
... (truncated 38139 chars, full result in C:\Users\PEDROH~1\AppData\Local\Temp\claude\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\tasks\whd6gxgcf.output)</result>
<diagnostics>Per-agent results: C:\Users\PedroHumbertoZúñigaC\.claude\projects\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\subagents\workflows\wf_0fcfc002-e0b/journal.jsonl — one {"type":"result",...} line per completed agent with its full return value.
If the result above is empty or unexpected, Read this file BEFORE diagnosing — do not assume agents returned non-empty results.
To re-run with edited post-processing: Workflow({scriptPath: 'C:\Users\PedroHumbertoZúñigaC\.claude\projects\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\workflows\scripts\auditoria-esquema-wms-wf_0fcfc002-e0b.js', resumeFromRunId: 'wf_0fcfc002-e0b'}) — agents whose (prompt, opts) are unchanged replay from cache.</diagnostics>
<usage><agent_count>20</agent_count><agents_done>20</agents_done><agents_error>0</agents_error><agents_skipped>0</agents_skipped><agents_empty_result>0</agents_empty_result><subagent_tokens>1049697</subagent_tokens><tool_uses>96</tool_uses><duration_ms>981478</duration_ms></usage>
</task-notification>

---

### [CLAUDE] · 2026-08-21 23:42:07 UTC

La auditoría encontró defectos reales. Leo el informe completo.

---

‹ 10 operaciones de herramienta: Bash×9, Write×1 ›

### [CLAUDE] · 2026-08-21 23:45:15 UTC

Auditoría cerrada: **23 hallazgos brutos → 17 confirmados tras refutación adversarial, 13 tras fusión — 3 críticos**. Tres eran bugs reales que habrían llegado a producción. Los aplico.

---

‹ 2 operaciones de herramienta: Write×2 ›

### [CLAUDE] · 2026-08-21 23:48:50 UTC

Ahora el documento de especificación consolidado.

---

‹ 2 operaciones de herramienta: Write×1, Bash×1 ›

### [CLAUDE] · 2026-08-21 23:52:13 UTC

Los residuos son solo la tabla de renombrados, que debe citarlos. Corrijo un código de error impreciso que se me coló:

---

‹ 3 operaciones de herramienta: Edit×3 ›

### [CLAUDE] · 2026-08-21 23:53:16 UTC

Esquema, auditoría y especificación cerrados. Tres archivos escritos:

- [db/migraciones/0001_esquema.sql](db/migraciones/0001_esquema.sql) — 12 tablas, 19 índices, 58 constraints
- [db/migraciones/0002_logica.sql](db/migraciones/0002_logica.sql) — 16 funciones, 14 triggers, 8 vistas
- [docs/superpowers/specs/2026-08-21-mini-wms-ordenes-design.md](docs/superpowers/specs/2026-08-21-mini-wms-ordenes-design.md) — especificación completa

---

## 1 · Esquema actualizado

**Discriminador aplicado** (sin él la clasificación sería ad-hoc y dos personas llegarían a resultados distintos):

> `rel_` → la fila **no tiene ciclo de vida propio**: existe solo como componente de un padre y muere con él (`CASCADE`).
> `tbl_` → la fila **sobrevive** a las transacciones que la tocan, tiene estado propio, otras entidades se le restringen (`RESTRICT`).
> `cat_` → dato de referencia: se lee mucho, se escribe poco, su borrado está restringido por definición.

| Tabla | Propósito | PK |
|---|---|---|
| `cat_categorias` | Categorías + contador de acuñación de SKU | `id` |
| `cat_almacenes` | Almacenes con código de longitud fija `ALM-XXX` | `id` |
| `cat_reglas_sku` | Regex dinámicas del SKU (una activa, garantizado por índice parcial) | `id` |
| `cat_clientes` | Clientes con código opaco `CLI-0001` | `id` |
| `cat_productos` | Productos con SKU acuñado e inmutable | `id` |
| **`tbl_inventario`** | Existencias por producto/almacén | **`(producto_id, almacen_id)`** |
| `tbl_ordenes` | Órdenes con máquina de estados | `id` |
| **`rel_orden_producto`** | Partidas con precio congelado | `id` + `uq(orden_id, producto_id)` |
| `tbl_movimientos_inventario` | Bitácora append-only de doble cubeta | `id` |
| `tbl_lotes_importacion` / `tbl_renglones_importacion` | Carga masiva y su resultado por renglón | `id` |
| `tbl_llaves_idempotencia` | Sobre de idempotencia HTTP | `llave` |

Nomenclatura extendida a objetos que no son tablas — **sin inventar prefijos de tabla**, que es lo que prohibiste: `pk_ uq_ fk_ ck_ ix_ ux_ trg_ fn_ vw_ seq_`. Columnas en español snake_case, sufijo `_en` para todo `timestamptz`, prefijo `es_` para todo `boolean`, excepciones léxicas declaradas (`sku`, `hash`, `jsonb`).

---

## 2 · Observaciones — la auditoría encontró tres bugs que habrían llegado a producción

Sometí el esquema a cinco auditores independientes con refutación adversarial: **23 hallazgos brutos → 17 confirmados → 13 tras fusión**.

**🔴 C1 — El índice único de idempotencia hacía inconfirmable toda orden multi-partida.** Mi `ux_tbl_movimientos__idempotencia` declaraba 1:1 lo que es 1:N: una petición produce **un movimiento por partida**, todos con la misma llave, así que la segunda chocaba con `23505`. Cualquier orden de 2+ productos era inconfirmable, inenviable e incancelable en cuanto .NET mandara `X-Idempotency-Key` — o sea, siempre. **Corregido:** unicidad de 4 columnas + llave derivada por renglón en la importación.

**🔴 C2 — Embarque no-op silencioso con reserva huérfana permanente.** `fn_enviar_orden` y `fn_cancelar_orden` no verificaban `IF NOT FOUND` tras el `UPDATE`, y nada congelaba `almacen_id` fuera de `BORRADOR`. Secuencia: confirmar en `ALM-NTE` → mover la orden a `ALM-SUR` → enviar → **0 filas afectadas en silencio** → orden `ENVIADA` (terminal), sin movimiento, con la reserva viva para siempre mermando `cantidad_disponible` sin forma de liberarla. **Corregido:** guardias en los tres bucles + trigger de encabezado inmutable.

**🔴 C3 — La acuñación de SKU se trababa de forma permanente.** El incremento era ciego (`+1`) y vivía en la misma transacción que el `INSERT`. Si una semilla insertaba un consecutivo explícito sin tocar el contador, cada alta nueva colisionaba, el rollback revertía también el incremento, y **esa categoría quedaba imposible de dar de alta para siempre** — con un `23505` opaco que Polly reintentaba en balde. **Corregido:** `greatest(contador, max real) + 1`, autorreparable, con trigger de sincronización.

**🟠 A1 — El contexto GUC falsificaba la bitácora.** Ninguna función limpiaba el contexto al salir, así que una segunda escritura en la misma transacción heredaba tipo, origen, `orden_id`, motivo y actor de la anterior, quedando grabada como un hecho falso **e inmutable** que el `CHECK` de coherencia no podía detectar porque el par heredado era internamente consistente. **Corregido:** limpieza explícita + `CHECK` de tipo contra delta.

Además: errores de negocio migrados a una clase SQLSTATE propia `WM001`–`WM012` (diez `RAISE` compartían `23514`, lo que forzaba a .NET a hacer string-matching sobre mensajes en español); `sku_historico` eliminado por redundancia pura; trazabilidad por renglón en importación; vistas de lectura para órdenes; fuentes de agregación para la gráfica obligatoria del dashboard.

**Descartados por el verificador** (evaluados, no aplicados): *"`tbl_inventario` debería ser `rel_`"* — incumple el discriminador en sus tres puntos; *"el ajuste rápido no tiene concurrencia efectiva"* — el `IF NOT FOUND` es el detector del conflicto, no código muerto; *"`unique(llave, ruta)` en idempotencia"* — habría **debilitado** la unicidad existente.

### ⚠️ Casos señalados por la regla 3

**`tbl_inventario`.** Formalmente parece `rel_` — PK compuesta de dos FK y nada más. Pero clasificarla así sería **activamente engañoso** frente a tu regla 6: diría "tabla puente, sigue de largo" sobre la tabla más volátil y crítica del sistema. Además incumple el discriminador en los tres puntos (FK `RESTRICT`, estado mutable propio, y es tabla *referenciada* por la bitácora). → `tbl_`.

**`tbl_llaves_idempotencia`.** No es catálogo, no es dato de negocio, no relaciona entidades: es infraestructura de protocolo con TTL de 48 h. Ninguno de los tres encaja; `tbl_` es la menos mala.

**`cat_reglas_sku`** es configuración, no catálogo de negocio, pero cabe en tu definición de `cat_`. Lo anoto solo para que no sorprenda.

### Cuatro puntos que necesitan tu ratificación

| # | Punto | Mi recomendación |
|---|---|---|
| 1 | `rel_orden_producto` singular (**tu ejemplo**) vs `rel_ordenes_productos` plural como el resto | **Mantener tu nomenclatura.** El costo es un `[Table]` en EF Core; cambiar tu ejemplo explícito sin preguntarte sería peor |
| 2 | `version_ecc` → `version_concurrencia` (**tú nombraste `version_ecc`** en el brief) | Renombrar: `ecc` es abreviatura opaca en inglés y contradice la convención que acabas de fijar. Ya aplicado, reversible con un `sed` |
| 3 | `cat_productos.estatus` (3 valores) vs `es_activo` en los otros 4 catálogos | Mantener por cardinalidad, documentado como excepción explícita |
| 4 | `tbl_llaves_idempotencia` y `tbl_inventario` con `tbl_` | Aceptar |

---

## 3 · Documento de especificación

Continúa desde donde íbamos, con la nomenclatura definitiva en todas las referencias. Secciones: convenciones y discriminador · inventario de tablas · mapa de relaciones y política de borrado · las cuatro piezas de ingeniería (acuñación de SKU, los **cuatro** mecanismos de concurrencia y qué problema distinto resuelve cada uno, bitácora de doble cubeta, idempotencia en dos niveles) · redundancias declaradas con su garantía del motor · 12 ambigüedades del enunciado resueltas · arquitectura .NET 8 Vertical Slice + CQRS con mapeo SQLSTATE→HTTP · 22 endpoints · plantilla de importación · matriz de 48 pruebas (incluidas 4 de regresión para C1, C2, C3 y A1) · Docker y semilla · alcance excluido con sus puntos de extensión.

**Una salvedad de honestidad:** el DDL pasó auditoría **estática** por cinco agentes, no ejecución contra un motor real. Por eso la prueba `I0` de la matriz es literalmente *"aplicar `0001` + `0002` sobre Postgres limpio"* — es lo primero que valida este documento en Fase 2.

Los agentes BACKEND y FRONTEND siguen bloqueados. ¿Ratificas los cuatro puntos y arrancamos la Fase 2, o quieres ajustar algo del esquema antes?

---
