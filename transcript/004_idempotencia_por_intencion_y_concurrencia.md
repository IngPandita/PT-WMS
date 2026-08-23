# 004 · Idempotencia por intención y concurrencia

**Periodo:** 2026-08-22 02:25:16 UTC → 2026-08-22 03:16:15 UTC

**Intervenciones en este archivo:** 1 del usuario, 13 de Claude, 1 del sistema.

---

### [USUARIO] · 2026-08-22 02:25:16 UTC

Quiero aclarar un punto importante de la especificación anterior.

No quiero que la protección contra doble ejecución dependa únicamente del `debounce` del frontend ni de que el usuario haga dos clics dentro de una ventana determinada de tiempo.

El escenario que debemos proteger es el siguiente:

1. El usuario abre un modal para realizar un movimiento.
2. Indica, por ejemplo, una cantidad de `2`.
3. Hace clic en confirmar.
4. Debido a una conexión lenta o algún problema de comunicación, el frontend no recibe respuesta inmediatamente y el modal puede permanecer disponible.
5. El usuario vuelve a hacer clic después de 500 ms, 2 segundos, 5 segundos o cualquier otro intervalo.
6. No debe existir la posibilidad de que el mismo movimiento termine aplicándose dos veces únicamente porque las dos solicitudes llegaron al backend.

Por lo tanto, quiero que la solución garantice la **idempotencia de la operación en backend/base de datos**, independientemente del comportamiento del debounce o de la velocidad de conexión.

Cada operación de movimiento debe tener un identificador único de operación (`operation_id`, `request_id` o un nombre equivalente).

El backend debe garantizar que una misma operación no pueda aplicarse dos veces.

Por ejemplo:

```text
Producto = 123
Cantidad = +2
operation_id = ABC123
```

Si por cualquier motivo llegan:

```text
Solicitud 1 → operation_id = ABC123
Solicitud 2 → operation_id = ABC123
```

el resultado debe ser únicamente:

```text
cantidad_base + 2
```

y nunca:

```text
cantidad_base + 2 + 2
```

La segunda solicitud debe reconocerse como una repetición de una operación ya procesada y no debe volver a generar el movimiento.

### Importante sobre la cancelación

No quiero asumir que cancelar una solicitud HTTP desde el frontend significa que la operación ya no puede ejecutarse en el backend.

Si la solicitud ya llegó al servidor y la transacción ya fue procesada o hizo `commit`, cancelar posteriormente la petición desde el cliente no revierte automáticamente dicha operación.

Por eso:

* La cancelación en frontend debe mantenerse como mecanismo de UX y optimización.
* El `debounce` puede mantenerse para reducir solicitudes accidentales.
* Pero la **garantía de no duplicar movimientos debe estar en backend/base de datos mediante idempotencia y restricciones apropiadas**.

### Concurrencia

También considera el caso en que dos usuarios diferentes realizan movimientos sobre el mismo producto simultáneamente.

En ese escenario sí deben contabilizarse ambos movimientos:

```text
cantidad_base + cantidad_usuario1 + cantidad_usuario2
```

pero cada movimiento debe tener su propio identificador, usuario, fecha/hora y demás información de auditoría.

Por ejemplo:

```text
Movimiento A
Producto: 123
Cantidad: +2
Usuario: 10
operation_id: AAA
Fecha: ...

Movimiento B
Producto: 123
Cantidad: +3
Usuario: 20
operation_id: BBB
Fecha: ...
```

El resultado debe ser:

```text
cantidad_base + 2 + 3
```

Mientras que si el usuario 10 reintenta accidentalmente la operación `AAA`, ese reintento **no debe volver a sumar 2**.

### Quiero que actualices la especificación

Revisa la implementación actual y determina si realmente garantiza este comportamiento.

En particular, verifica:

1. Qué sucede si el usuario hace doble clic rápidamente.
2. Qué sucede si hace dos clics separados por varios segundos.
3. Qué sucede si la conexión es muy lenta.
4. Qué sucede si el frontend cancela una solicitud que ya llegó al backend.
5. Qué sucede si el usuario recibe un timeout pero el backend sí procesó la operación.
6. Qué sucede si el navegador reintenta la solicitud.
7. Qué sucede si dos usuarios modifican simultáneamente el mismo producto.
8. Cómo se garantiza mediante PostgreSQL que una misma operación no pueda aplicarse dos veces.
9. Cómo interactúan `operation_id`, transacciones, `rollback` y `commit`.
10. Qué ocurre si la aplicación falla después de guardar el movimiento pero antes de responder al frontend.

No quiero que la solución dependa de tiempos específicos como `250 ms` para garantizar integridad.

El objetivo final es:

**Una operación del usuario = un solo movimiento aplicado.**

Un reintento de la misma operación debe ser seguro e idempotente.

Dos operaciones legítimas de usuarios diferentes deben poder ejecutarse y contabilizarse independientemente.

Además, conserva la trazabilidad del movimiento mediante usuario, fecha/hora, producto, cantidad y `operation_id`, incluso cuando posteriormente se utilice soft-delete.

Finalmente, actualiza el documento de especificación para reflejar esta garantía y señala cualquier cambio necesario en el esquema de PostgreSQL, API y frontend.

---

### [CLAUDE] · 2026-08-22 02:26:51 UTC

Tienes razón y el señalamiento es exacto: **mi garantía dependía de una decisión del cliente** — acuñar una llave nueva por petición. Eso vacía la idempotencia justo en tu escenario. Audito la implementación actual contra tus 10 casos y la corrijo.

---

‹ 25 operaciones de herramienta: Bash×20, Write×3, Edit×1, Workflow×1 ›

### [CLAUDE] · 2026-08-22 02:38:09 UTC

Auditoría lanzada. Mientras corre, el diagnóstico honesto de lo que estaba mal:

## Tu señalamiento era correcto: la garantía estaba en el lugar equivocado

Audité la implementación anterior contra tus 10 escenarios:

| # | Escenario | Diseño anterior |
|---|---|---|
| 1 | Doble clic rápido | ⚠️ Solo lo salvaba el debounce |
| 2 | Dos clics separados | ❌ **Dos llaves distintas → dos operaciones** |
| 3 | Conexión lenta | ❌ **Duplicaba** |
| 4 | Cancelar algo que ya llegó | ✅ |
| 5 | **Timeout con el backend procesando** | ❌ **El reintento acuñaba llave nueva → duplicaba** |
| 6 | Reintento del navegador | ⚠️ Parcial |
| 7 | Dos usuarios simultáneos | ✅ |
| 8 | Garantía en PostgreSQL | ⚠️ El índice existía, pero **la llave no era estable entre reintentos, así que nunca colisionaba** |
| 10 | Fallo tras guardar, antes de responder | ❌ **Duplicaba** |

La causa raíz es exactamente la que apuntaste: **acuñaba la llave por petición, no por operación.** La maquinaria de idempotencia era correcta y estaba en la base de datos — pero una decisión del cliente la volvía inoperante justo en tu escenario.

## Lo que cambió

**`id_operacion` identifica una intención, no una petición.** Se acuña al abrir el modal y se reutiliza en cada clic de Confirmar, cada reintento por timeout, cada reconexión. Se invalida solo al aplicarse, o si el usuario **cambia la cantidad** (eso sí es otra intención — por eso el campo se congela mientras hay una operación en vuelo, aunque **el botón no**: reintentar debe ser posible y es seguro).

**Dos barreras, la segunda ineludible:**

1. `pk_tbl_operaciones` — el reenvío recibe `YA_COMPLETADA` con la respuesta original, sin ejecutar nada.
2. `ux_tbl_movimientos_inventario__operacion (id_operacion, producto_id, almacen_id, tipo_movimiento)` — y aquí está el punto: **el trigger escribe la bitácora dentro de la misma transacción que muta `tbl_inventario`**, así que violar ese índice **revierte también la existencia**. Aunque la aplicación fallara por completo, la doble aplicación es físicamente imposible. `id_operacion` es `NOT NULL`: ningún movimiento puede quedar fuera de ese control.

**El sellado va dentro de la transacción de trabajo.** Si estuviera fuera existiría un instante con el movimiento confirmado y la operación aún `EN_PROCESO`: un reenvío recibiría 409 en vez de la respuesta correcta, y el barrido acabaría marcando `FALLIDO` algo que sí se aplicó. Dentro, movimiento y sello confirman o fracasan juntos — que es la respuesta a tu escenario 10.

**Un fallo deja `FALLIDO`, no `COMPLETADO`** — y por tanto reejecutable con el mismo id. Esa distinción es la que hace que reintentos e idempotencia convivan sin bloquearse.

## Eliminé el protocolo de supersesión completo

Cancelar y compensar era la forma *indirecta* de evitar duplicados. Con idempotencia real sobra, y con él desaparecen el `40P01` estructural, la compensación transitiva, `deuda`, `compensado_por`, `llave_supersede`, `efecto`, los estatus `SUPERSEDIDO`/`CANCELADO`, dos funciones y toda una fase. La cancelación se queda con su alcance honesto, declarado en una tabla del spec: `AbortController` y `debounce` son **UX y ahorro de tráfico**; `id_operacion` + índice único son **la integridad**.

El resultado que pediste, ahora sin depender del reloj: 3 clics en 100 ms → 1 operación de `+3`; 3 clics en 10 segundos → 3 operaciones de `+1`. **`base + 3` en ambos casos.**

**Estado:** 13 tablas, 25 funciones, 27 triggers, 9 vistas, 47 pruebas de integración. Nueva §3.7 responde tus diez escenarios uno por uno. Te reporto los hallazgos de la auditoría en cuanto cierre — y sigue vigente que **el SQL no se ha ejecutado contra un Postgres real**; esa es la primera tarea de la Fase 2.

---

### [SISTEMA — notificación de tarea en segundo plano] · 2026-08-22 03:02:20 UTC

<task-notification>
<task-id>w34l0obph</task-id>
<tool-use-id>toolu_01AyLA2HBtR7oQTCuLrLrabq</tool-use-id>
<output-file>C:\Users\PEDROH~1\AppData\Local\Temp\claude\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\tasks\w34l0obph.output</output-file>
<status>completed</status>
<summary>Dynamic workflow "Verifica adversarialmente que una operacion del usuario no pueda aplicarse dos veces en el Mini WMS" completed</summary>
<result>{"total":20,"confirmados":18,"sintesis":"INFORME DE AUDITORIA CONSOLIDADO — Mini-WMS / idempotencia de operaciones\nRequisito auditado: \"una operacion del usuario = un solo movimiento aplicado\".\n14 hallazgos confirmados tras fusion de duplicados (4 pares/tercias fusionados). 2 refutados.\n\n=====================================================================\nCRITICOS\n=====================================================================\n\nC1. 0002_logica.sql no se ejecuta: `as $` en vez de `as $$`\n  (fusion de 3 hallazgos: lente postgres, lente trazabilidad, y nota colateral en el barrido)\n  Objeto: db/migraciones/0002_logica.sql lineas 175, 595, 643\n          (fn_fijar_contexto_movimiento, fn_confirmar_orden, fn_enviar_orden)\n  Rompe: la migracion aborta en la linea 176 con `ERROR: syntax error at or near \"$\"`, asi que\n  NO existen ni fn_reservar_operacion (barrera 1) ni el trigger trg_tbl_inventario__bitacora\n  —unico escritor de tbl_movimientos_inventario, verificado por grep—, con lo que\n  ux_tbl_movimientos_inventario__operacion (barrera 2) nunca llega a evaluarse: cero garantia.\n  Reproducido en PostgreSQL 15.19: 2 clics con el mismo id_operacion -&gt; fisica=4, bitacora=0.\n  Corregidas las 3 lineas, el mismo escenario da 23505 y fisica=2.\n  Agravante: sin ON_ERROR_STOP psql emite 135 errores y sale con EXIT CODE 0, dejando 14 triggers\n  sueltos y el indice de barrera 2 presente sobre una tabla que nadie escribe.\n  Fix:\n    sed -i '175s/as \\$$/as $$/; 595s/as \\$$/as $$/; 643s/as \\$$/as $$/' db/migraciones/0002_logica.sql\n    # verificacion: grep -nE 'as +\\$([^$]|$)' db/migraciones/*.sql  -&gt; cero lineas\n    # pipeline: psql -v ON_ERROR_STOP=1 --single-transaction -f 0001_esquema.sql\n    #           psql -v ON_ERROR_STOP=1 --single-transaction -f 0002_logica.sql\n    # humo (debe devolver 1, no dividir por cero):\n    select 1/(case when exists(select 1 from pg_trigger where tgname='trg_tbl_inventario__bitacora' and not tgisinternal)\n                    and exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace\n                               where n.nspname='wms' and p.proname='fn_reservar_operacion')\n              then 1 else 0 end);\n  NOTA: un guard de CI por paridad de `$` es insuficiente (2 erratas dan paridad par). Usar el grep de patron.\n\nC2. La importacion commitea trabajo fuera del sellado: doble aplicacion real\n  Objeto: spec §3.3 (\"chunks de 500 renglones por transaccion\") + §3.5 (el id se acuña al SELECCIONAR\n          EL ARCHIVO) + 0001_esquema.sql:349-373 (tbl_lotes_importacion.id_operacion) + 0002:394-405\n  Rompe: cada chunk COMMITEA mientras tbl_operaciones sigue EN_PROCESO, asi que FALLIDO deja de\n  significar \"no se aplico nada\" (premisa escrita en 0002:407-409 y 375-376). Al reintentar, el usuario\n  reselecciona el archivo, acuña LOTE-BBBB, y las llaves 'LOTE-BBBB:n' NO colisionan con las\n  'LOTE-AAAA:n' ya aplicadas: los 3000 renglones se aplican OTRA VEZ sin violar ninguna constraint.\n  Rama alterna (mismo id): el renglon 1 lanza 23505 y, como NO existe ni un `exception when` ni un\n  `savepoint` en todo 0002 (grep: cero coincidencias), mata el chunk entero de 500 y la reimportacion\n  no avanza nunca. La promesa \"reimportar es un no-op exacto renglon por renglon\" es falsa en ambas ramas.\n  Agravante: tbl_lotes_importacion.id_operacion es NULLABLE y sin indice unico -&gt; dos filas de lote\n  para el mismo X-Operation-Id; y el barrido a 5 min sentencia en vuelo toda importacion larga.\n  Fix (SQL):\n    alter table wms.tbl_lotes_importacion alter column id_operacion set not null;\n    create unique index ux_tbl_lotes_importacion__operacion on wms.tbl_lotes_importacion (id_operacion);\n    alter table wms.tbl_renglones_importacion\n      add constraint fk_tbl_renglones_importacion__movimientos\n      foreign key (movimiento_id) references wms.tbl_movimientos_inventario (id) on delete restrict;\n    -- sacar la importacion del barrido (su avance vive en tbl_lotes_importacion.estatus):\n    ... where estatus='EN_PROCESO' and creado_en &lt; now()-p_antiguedad and alcance not like 'importacion:%';\n  Fix (.NET, no expresable en el esquema):\n    - insert ... on conflict (id_operacion) do nothing + select de la fila; REANUDAR desde el primer\n      numero_renglon que no este OK. La llave por renglon se construye con el id_operacion LEIDO, no armado.\n    - cada renglon bajo su propio SAVEPOINT; 23505 sobre ux_...__operacion -&gt; rollback to savepoint +\n      estatus='OMITIDO', codigo_error='YA_APLICADO' (ck_tbl_renglones_importacion__codigo_error ya lo admite).\n    - alternativa preferible: cada chunk reserva y sella su propia operacion '&lt;lote&gt;:chunk=&lt;n&gt;'.\n  Fix (spec): §3.5 debe acuñar el id de importacion por HASH DEL CONTENIDO, no \"al seleccionar el archivo\".\n  §3.6 debe declarar que la importacion es la unica operacion cuyo sellado no es cotransaccional.\n\nC3. El hash de idempotencia incluye campos que no son la intencion: 409 espurio -&gt; re-acuñado -&gt; +2 dos veces\n  Objeto: 0002_logica.sql:361-364 (comparacion de hash) + contrato §3.2:626\n          {producto_id, almacen_id, delta, motivo, version_esperada?} + regla de congelado §3.5:716\n  Rompe: barrera 1 es MAS SEVERA que barrera 2. ux_...__operacion (0001:504) define identidad como\n  (id_operacion, producto_id, almacen_id, tipo_movimiento) y deja 'motivo' fuera a proposito; el hash,\n  segun la unica lectura disponible, lo incluye. §3.5 congela solo la cantidad y declara que editar el\n  motivo NO invalida el id: el diseño ordena reenviar el mismo id y a la vez permite mover el hash.\n  La comparacion esta ANTES de la rama de estatus (361 precede a 366), asi que una vez tomada la fila\n  con el hash viejo NINGUN reenvio alcanza jamas YA_COMPLETADA: 409/WM015 permanente. El usuario cierra\n  y reabre el modal (id nuevo por diseño) y confirma: la barrera 2 no aplica porque el id es otro -&gt;\n  existencia base+4, el resultado que I34/E3 declaran imposible.\n  Fix (normativo, sin cambio estructural de SQL):\n    - Redefinir hash_peticion (comentario 0001:539-540 y §1.4): SHA-256 del JSON canonico de EXACTAMENTE\n      los campos de la intencion. /api/inventario/ajustar: {almacen_id, delta, producto_id,\n      tipo_movimiento, usuario_id}. /api/ordenes/{id}/{accion}: {accion, orden_id, usuario_id}.\n      /api/importacion: {hash_archivo, modo, usuario_id}. EXCLUIDOS motivo, version_esperada, timestamps\n      y nonces. ausente/null/'' se normalizan al mismo valor. Regla: el conjunto del hash debe ser\n      superconjunto de las columnas de ux_...__operacion y nada mas.\n    - §3.2:626: marcar `motivo?` y anotar que no participa del hash.\n    - §3.5: PROHIBIDO re-acuñar el id tras 409/WM015; la unica accion segura es\n      GET /api/inventario/movimientos?id_operacion=&lt;id&gt; antes de permitir cualquier envio nuevo\n      (requiere añadir ese filtro; ix_tbl_movimientos_inventario__id_operacion ya lo soporta).\n    - §3.5:696: corregir \"aun asi lo detiene el indice unico\" -&gt; solo detiene la repeticion del MISMO id.\n    - §3.8: añadir U11 (el hash ignora motivo/version_esperada) e I48 (mismo id, motivo editado entre\n      clics -&gt; YA_COMPLETADA/200, un solo movimiento, base+2).\n  Matiz: el falso positivo no es universal; solo dispara si el motivo se edita o la version se refresca.\n\n=====================================================================\nALTOS\n=====================================================================\n\nA1. id_operacion sin espacio de nombres por usuario: se traga el movimiento del segundo operador y responde 200\n  (severidad original CRITICA; el verificador la ajusta a ALTA porque el disparador rompe tambien el caso mono-usuario)\n  Objeto: pk_tbl_operaciones (0001:550), ck_tbl_operaciones__formato (0001:560),\n          fn_reservar_operacion (0002:339-389), ux_...__operacion (0001:504)\n  Rompe: la PK es global sobre un texto que acuña
... (truncated 21118 chars, full result in C:\Users\PEDROH~1\AppData\Local\Temp\claude\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\tasks\w34l0obph.output)</result>
<diagnostics>Per-agent results: C:\Users\PedroHumbertoZúñigaC\.claude\projects\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\subagents\workflows\wf_d0dbc487-bf6/journal.jsonl — one {"type":"result",...} line per completed agent with its full return value.
If the result above is empty or unexpected, Read this file BEFORE diagnosing — do not assume agents returned non-empty results.
To re-run with edited post-processing: Workflow({scriptPath: 'C:\Users\PedroHumbertoZúñigaC\.claude\projects\C--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\workflows\scripts\auditoria-idempotencia-wms-wf_d0dbc487-bf6.js', resumeFromRunId: 'wf_d0dbc487-bf6'}) — agents whose (prompt, opts) are unchanged replay from cache.</diagnostics>
<usage><agent_count>17</agent_count><agents_done>17</agents_done><agents_error>0</agents_error><agents_skipped>0</agents_skipped><agents_empty_result>0</agents_empty_result><subagent_tokens>1517026</subagent_tokens><tool_uses>239</tool_uses><duration_ms>1475470</duration_ms></usage>
</task-notification>

---

### [CLAUDE] · 2026-08-22 03:02:34 UTC

La auditoría reporta un **showstopper**: el SQL no parsea. Lo verifico antes de aceptarlo.

---

‹ 2 operaciones de herramienta: Bash×2 ›

### [CLAUDE] · 2026-08-22 03:03:27 UTC

**Los auditores tienen razón y yo me equivoqué al verificar** — `cat -A` renderiza el fin de línea como `$`, así que leí `as $$` donde había `as $`. A nivel de bytes está confirmado. La causa raíz es mía: en JavaScript, `$$` dentro del reemplazo de `String.replace` es un escape que produce **un solo** `$`. Cada parche mío con `$$` quedó corrupto.

---

‹ 3 operaciones de herramienta: Bash×3 ›

### [CLAUDE] · 2026-08-22 03:04:05 UTC

Corregido y balanceado (50 delimitadores = 25 funciones × 2). Ahora intento **ejecutarlo de verdad** contra un Postgres, que es lo que falta desde el principio.

---

‹ 5 operaciones de herramienta: Bash×5 ›

### [CLAUDE] · 2026-08-22 03:05:09 UTC

**Ambas migraciones aplican limpiamente contra PostgreSQL 16.** Es la primera vez que `I0` pasa de verdad. Ahora ejecuto tu escenario exacto.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 03:06:04 UTC

El escenario central pasa contra Postgres real. Veo el resto de las barreras:

---

‹ 3 operaciones de herramienta: Bash×3 ›

### [CLAUDE] · 2026-08-22 03:06:41 UTC

Todas las barreras pasan contra Postgres real. Leo el resto del informe:

---

‹ 2 operaciones de herramienta: Bash×2 ›

### [CLAUDE] · 2026-08-22 03:07:34 UTC

Ahora aplico los hallazgos confirmados. Empiezo por el más grave después de C1 — **A2**, que produce el efecto inverso: cero aplicaciones reportadas como éxito.

---

‹ 9 operaciones de herramienta: Bash×4, Edit×3, Write×2 ›

### [CLAUDE] · 2026-08-22 03:10:38 UTC

Un hallazgo propio de la ejecución: el `CHECK` dispara **antes** del `ON CONFLICT`, así que el caso A1 sale como `23514` crudo en vez del veredicto limpio. Lo corrijo.

---

‹ 2 operaciones de herramienta: Edit×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 03:11:09 UTC

Ahora verifico **A5**: que el rol de la aplicación no pueda falsificar la bitácora pero sí operar.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 03:11:31 UTC

**A5 cerrado y verificado.** Copio la prueba al repositorio como artefacto y actualizo la especificación.

---

‹ 12 operaciones de herramienta: Bash×8, Write×2, Edit×2 ›

### [CLAUDE] · 2026-08-22 03:16:15 UTC

La tercera auditoría encontró un **showstopper que invalidaba todo lo anterior**, y expuso un fallo de método mío.

## 🔴 El archivo no compilaba

Tres funciones abrían su cuerpo con `as $` en vez de `as $$`. La migración abortaba, así que **no existía ni la barrera 1 ni el trigger de bitácora** — y el índice de la barrera 2 protegía una tabla que nadie escribía. Garantía cero.

**Causa raíz, y es mía:** en JavaScript, `$$` dentro del reemplazo de `String.replace` es un escape que produce **un solo** `$`. Mis parches automatizados corrompieron el archivo en silencio. Dos rondas de auditoría estática no lo vieron. Peor: cuando fui a verificar el hallazgo, leí `cat -A` y vi `as $$` donde había `as $` — porque `cat -A` renderiza el fin de línea como `$`. Casi descarto un hallazgo correcto por leer mal mi propia verificación.

Lo que faltaba no era otra revisión. Era **ejecutar el SQL**.

## Ahora está ejecutado

Levanté un PostgreSQL 16 en Docker y corrí todo. `db/pruebas/verificar.sh` lo reproduce en un comando:

```
0001_esquema.sql   OK      0002_logica.sql   OK      0003_permisos.sql   OK
PASA  reclic del modal rechazado por el motor (23505)      ← tu escenario
PASA  reintento accidental de AAA rechazado
PASA  ck_tbl_operaciones__prefijo_actor bloqueó el id ajeno
PASA  bitácora inmutable (WM006)     PASA  TRUNCATE bloqueado (WM006)
PASA  sobreventa bloqueada (WM002)   PASA  SKU inmutable (WM003)
PASA  INSERT directo denegado al rol de la aplicación
existencia=17  suma_bitacora=17  cuadra=t
```

Tu escenario literal, contra motor real: base 10 → clic `+2` → **12**; reclic con el mismo `id_operacion` → `23505`, existencia sigue en **12**. Usuario 2 aporta `+2`, usuario 3 aporta `+3` → **17**, tres renglones con su operador y fecha. Reintento accidental de `AAA` → rechazado.

## Otros cinco defectos reales

**La importación confirmaba por partes**, así que `FALLIDO` no significaba "no se aplicó nada". Un reintento que reseleccionaba el archivo acuñaba un id nuevo y **reaplicaba los 3 000 renglones** sin violar nada. Ahora el id se deriva del **contenido** del archivo, el lote es único, se reanuda desde el primer renglón no-`OK` y cada renglón corre bajo su propio `SAVEPOINT`.

**El hash incluía `motivo` y `version_esperada`** — campos que no son la intención. Editar el motivo entre clics producía `WM015` permanente; el usuario cerraba el modal, acuñaba un id nuevo, y se aplicaba dos veces. Un hash demasiado amplio **causa** la duplicación que pretende evitar. Ahora está definido normativamente: superconjunto de las columnas del índice único y nada más.

**`alcance` y `ruta` se guardaban y nunca se comparaban.** `/ordenes/12/confirmar` y `/ordenes/12/enviar` tienen ambos cuerpo vacío: con el mismo id, el envío recibía `200` con la respuesta de la confirmación y **el embarque no ocurría jamás**. Es el espejo del problema: cero aplicaciones reportadas como éxito.

**`id_operacion` sin espacio de nombres por operador.** Dos operadores con el mismo id y cuerpo idéntico → el segundo recibía `200` con la respuesta del primero y su movimiento desaparecía. Ahora el id lleva `<usuario_id>:` obligado por dos `CHECK`. Al implementarlo descubrí en ejecución que el `CHECK` dispara antes del `ON CONFLICT`, devolviendo un `23514` crudo — lo moví a validación previa para que salga un veredicto limpio.

**La bitácora aceptaba `INSERT` directo.** El trigger de inmutabilidad solo cubre `UPDATE`/`DELETE`/`TRUNCATE`, y el rol que la API necesita para operar era el mismo que le permitía falsificar el historial. Nuevo `0003_permisos.sql`: el trigger pasa a `SECURITY DEFINER` y se revoca `INSERT` a `wms_api`. Verificado: *permission denied* al falsificador, la API sigue operando, y `sum(delta_fisica) = cantidad_fisica` se sostiene.

## Un residual que declaro en vez de esconder

Para rutas que no generan movimiento **y** no tienen unicidad natural — el alta de producto — la protección es solo la barrera 1, con ventana de 48 h. Un reintento pasada esa ventana no es un reintento. Está documentado en la especificación.

También añadí al spec por qué el pipeline usa `psql -v ON_ERROR_STOP=1`: sin esa bandera, `psql` imprime los errores y **sale con código 0**. Es literalmente cómo un archivo que no compilaba pudo darse por bueno.

**Entregables:** tres migraciones, suite de humo, script de verificación reproducible y la especificación actualizada. El encabezado ya no dice "no ejecutado".

---
