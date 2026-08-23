# 003 · Doble clic, transacciones, soft-delete y trazabilidad

**Periodo:** 2026-08-22 00:09:55 UTC → 2026-08-22 02:15:55 UTC

**Intervenciones en este archivo:** 1 del usuario, 13 de Claude, 1 del sistema.

---

### [USUARIO] · 2026-08-22 00:09:55 UTC

Confirmo los cambios propuestos. Quiero que ajustes la especificación funcional y técnica considerando los siguientes criterios para el manejo de solicitudes, errores de conexión y movimientos de inventario/datos.

### 1. Manejo de múltiples solicitudes por doble clic

Cuando un usuario realice una acción que genere una solicitud al backend y, por ejemplo, haga doble clic provocando dos solicitudes consecutivas, el frontend debe manejarlo de la siguiente manera:

* La solicitud correspondiente al **primer clic debe ser cancelada**.
* La solicitud correspondiente al **segundo clic debe permanecer activa y continuar su ejecución**.
* El objetivo es que solamente la solicitud más reciente del usuario continúe procesándose.
* Esto debe contemplarse especialmente para acciones que modifiquen información o generen movimientos.

No quiero simplemente bloquear permanentemente el botón después del primer clic como única estrategia. La lógica debe contemplar que, si existe una solicitud anterior en ejecución y el usuario genera una nueva solicitud válida, la anterior pueda ser cancelada y la nueva tome su lugar.

Analiza también cómo debe implementarse esto para evitar condiciones de carrera, solicitudes que lleguen fuera de orden o respuestas de una solicitud anterior que terminen sobrescribiendo el resultado de la solicitud más reciente.

### 2. Manejo de errores y transacciones de base de datos

Para todas las operaciones que **modifiquen la base de datos**, implementa un manejo robusto de errores.

Debe utilizarse:

* `try/catch` para capturar errores.
* Transacciones de base de datos.
* `rollback` cuando una operación falle.
* `commit` únicamente cuando todas las operaciones relacionadas hayan terminado correctamente.

El objetivo es evitar que una operación quede parcialmente aplicada debido a:

* Pérdida de conexión.
* Error inesperado del backend.
* Error de validación durante una operación.
* Fallo al insertar o actualizar alguna de las entidades relacionadas.
* Cancelación o interrupción de la solicitud.
* Cualquier otro error que pueda dejar información inconsistente.

Por ejemplo, si una operación requiere actualizar varias tablas y la actualización de la tercera falla, las modificaciones realizadas anteriormente deben revertirse mediante `rollback`.

No quiero operaciones que puedan quedar "a medias".

También especifica claramente qué ocurre cuando una solicitud es cancelada mientras una transacción ya está en ejecución y cómo se debe garantizar la consistencia de los datos.

### 3. Múltiples usuarios realizando movimientos sobre el mismo producto

Respecto al escenario en el que diferentes usuarios realizan solicitudes sobre el mismo producto de manera simultánea, la lógica propuesta me parece correcta:

**cantidad_final = cantidad_base + cantidad_usuario1 + cantidad_usuario2 + ...**

Sin embargo, quiero que esto se maneje mediante **movimientos individuales y trazables**, no únicamente acumulando un valor sin historial.

Cada movimiento debe guardar como mínimo:

* Producto involucrado.
* Cantidad del movimiento.
* Fecha y hora de creación.
* Usuario que realizó el movimiento.
* Identificador único del movimiento.
* Tipo de movimiento, cuando corresponda.
* Información necesaria para conocer el estado del movimiento.

Por ejemplo:

| Usuario   | Producto   | Cantidad | Fecha      |
| --------- | ---------- | -------: | ---------- |
| Usuario 1 | Producto A |       +5 | Fecha/Hora |
| Usuario 2 | Producto A |       +3 | Fecha/Hora |

El resultado acumulado sería equivalente a:

`cantidad_base + 5 + 3`

pero deben conservarse los dos movimientos de manera independiente.

### 4. Importancia de la fecha y usuario

Es indispensable conservar la **fecha de creación y el usuario responsable de cada movimiento**.

Esto es especialmente importante porque el sistema puede utilizar **soft-delete** o desactivación de registros.

No debemos depender únicamente del estado actual de un registro para reconstruir qué ocurrió históricamente.

Aunque posteriormente un usuario, producto, movimiento u otra entidad sea desactivado mediante soft-delete, el sistema debe conservar la trazabilidad necesaria para saber:

* Qué ocurrió.
* Quién lo realizó.
* Cuándo ocurrió.
* Qué cantidad se afectó.
* Qué registro o entidad estaba involucrado.

### 5. Concurrencia y consistencia

Analiza cómo debe manejarse la concurrencia cuando dos o más usuarios modifican simultáneamente el mismo producto.

La solución debe evitar:

* Pérdida de movimientos.
* Actualizaciones que sobrescriban movimientos anteriores.
* Duplicación accidental.
* Cantidades incorrectas.
* Condiciones de carrera.
* Datos parcialmente guardados.

Cuando sea necesario, utiliza mecanismos apropiados de base de datos, como transacciones, restricciones, locks o estrategias de control de concurrencia, pero evita agregar complejidad innecesaria.

### 6. Actualización de la especificación

Integra estos criterios directamente en el diseño existente.

No quiero que únicamente describas estos puntos de forma teórica. **Actualiza la especificación funcional y técnica, el esquema de base de datos y los flujos correspondientes para que estas reglas formen parte real de la solución.**

Si alguna de estas reglas entra en conflicto con una decisión de diseño anterior, identifica el conflicto, explica cuál sería la mejor solución y actualiza la especificación de acuerdo con ella.

Al finalizar, incluye una sección breve de **"Manejo de errores y concurrencia"** donde se explique de forma clara cómo el sistema garantiza que las operaciones no queden incompletas y que los movimientos de múltiples usuarios sean consistentes y auditables.

---

### [CLAUDE] · 2026-08-22 00:12:53 UTC

Confirmado. Estos criterios entran en conflicto real con dos decisiones previas, así que primero los integro en el esquema y después someto el protocolo resultante a auditoría adversarial. Empiezo por la base de datos.

---

‹ 7 operaciones de herramienta: Edit×7 ›

### [CLAUDE] · 2026-08-22 00:14:03 UTC

Ahora la bitácora — el corazón del requerimiento de trazabilidad:

---

‹ 5 operaciones de herramienta: Edit×5 ›

### [CLAUDE] · 2026-08-22 00:15:04 UTC

Ahora la lógica: contexto de usuario, protocolo de supersesión y vistas con trazabilidad completa.

---

‹ 1 operaciones de herramienta: Write×1 ›

### [CLAUDE] · 2026-08-22 00:17:30 UTC

Protocolo de supersesión y transacciones escritos en el esquema. Lo documento para los auditores y lanzo la verificación adversarial mientras redacto la especificación.

---

‹ 2 operaciones de herramienta: Write×1, Workflow×1 ›

### [CLAUDE] · 2026-08-22 00:19:36 UTC

Actualizo la especificación mientras corre la auditoría.

---

‹ 10 operaciones de herramienta: Edit×10 ›

### [CLAUDE] · 2026-08-22 00:22:20 UTC

Ahora la sección de cierre que pediste:

---

‹ 6 operaciones de herramienta: Edit×5, Bash×1 ›

### [CLAUDE] · 2026-08-22 00:24:02 UTC

Esquema y especificación actualizados: **13 tablas, 23 funciones, 22 triggers, 9 vistas**. Sin referencias obsoletas.

Lo sustantivo mientras cierra la auditoría — **identifiqué tres conflictos reales** entre tus criterios y decisiones previas:

**⚔️ 1. "Cancelar el primer clic" vs. delta conmutativo.** El ajuste rápido estaba diseñado como delta puro: dos clics en `+` = `+2`, y la prueba E3 lo verificaba. Cancelar la primera petición dejaría `+1` — el usuario perdería un clic que sí hizo. **Resolución:** el control pasa a *stepper con intención acumulada*. El cliente mantiene `baseConfirmada` + `deltaIntencion`, y cada petición envía el **acumulado**, no el clic individual. Así la petición reemplazada nunca cargaba la intención completa, y cancelarla deja de ser destructivo. Se cumple tu regla literal — solo sobrevive la más reciente — sin perder movimientos.

**⚔️ 2. "Estado del movimiento" vs. bitácora inmutable.** Pediste que cada movimiento guarde su estado; la bitácora es estrictamente append-only. Almacenar un estado mutable la volvería manipulable y destruiría su valor probatorio. **Resolución:** `estado` se **deriva** en vista (`APLICADO` / `CONSUMIDO` / `COMPENSADO`). Misma información, sin renunciar a la inmutabilidad.

**⚔️ 3. "Usuario responsable" vs. alcance sin autenticación.** **Resolución:** `cat_usuarios` como registro de operadores **sin credenciales**. Atribución completa sin construir identidad fuera de alcance. `fn_fijar_contexto_movimiento` y el trigger de bitácora abortan con `WM014` si el usuario falta, no existe o está inactivo — **ninguna mutación de existencia puede ser anónima, ni siquiera un `UPDATE` manual desde `psql`**.

El punto técnico más delicado que resolví: **cancelar en el cliente no cancela el trabajo en el servidor**. Si la petición A ya confirmó cuando B la reemplaza, B debe *compensar*, no ignorarla. Por eso `tbl_llaves_idempotencia` gana un protocolo de supersesión con `alcance`, `llave_supersede` y `efecto`, resuelto bajo row lock — y la reserva de la llave va en **conexión aparte con commit inmediato**, porque una fila no confirmada es invisible por MVCC y la supersesión no podría observarla.

🔄 Auditoría adversarial en curso sobre el protocolo (5 lentes: supersesión, transacciones/Npgsql, trazabilidad, semántica PostgreSQL y modelo de cliente). Te reporto los hallazgos en cuanto cierre.

---

### [SISTEMA — notificación de tarea en segundo plano] · 2026-08-22 00:51:53 UTC

<task-notification>
<task-id>wrt7xshv4</task-id>
<tool-use-id>toolu_01RAC4iRRi5GS83ifk1Znpz3</tool-use-id>
<output-file>C:\Users\PEDROH~1\AppData\Local\Temp\claude\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\tasks\wrt7xshv4.output</output-file>
<status>completed</status>
<summary>Dynamic workflow "Audita el protocolo de supersesion, transacciones y trazabilidad del Mini WMS con lentes adversariales" completed</summary>
<result>{"total":24,"confirmados":17,"sintesis":null}</result>
<diagnostics>Per-agent results: C:\Users\PedroHumbertoZúñigaC\.claude\projects\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\subagents\workflows\wf_c91bb6b8-783/journal.jsonl — one {"type":"result",...} line per completed agent with its full return value.
If the result above is empty or unexpected, Read this file BEFORE diagnosing — do not assume agents returned non-empty results.
To re-run with edited post-processing: Workflow({scriptPath: 'C:\Users\PedroHumbertoZúñigaC\.claude\projects\c--Users-PedroHumbertoZ--igaC-Documents-Sistemas-Pt-WMS\10fe2f78-5f58-435a-8d4c-4fe9d631f436\workflows\scripts\auditoria-supersesion-wms-wf_c91bb6b8-783.js', resumeFromRunId: 'wf_c91bb6b8-783'}) — agents whose (prompt, opts) are unchanged replay from cache.</diagnostics>
<failures>[sintesis] failed: API Error: The response stopped arriving. The response above may be incomplete.</failures>
<usage><agent_count>21</agent_count><agents_done>20</agents_done><agents_error>1</agents_error><agents_skipped>0</agents_skipped><agents_empty_result>0</agents_empty_result><subagent_tokens>1534379</subagent_tokens><tool_uses>237</tool_uses><duration_ms>1939766</duration_ms></usage>
</task-notification>

---

### [CLAUDE] · 2026-08-22 02:08:07 UTC

La síntesis falló por error de API, pero los 17 hallazgos confirmados están en el journal. Los extraigo directamente.

---

‹ 2 operaciones de herramienta: Write×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 02:08:29 UTC

Tres lentes independientes convergieron en un **deadlock estructural** en mi protocolo. Leo el detalle.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 02:10:28 UTC

La auditoría reprodujo un **deadlock 40P01 en el caso nominal del doble clic** — tres lentes independientes, con la secuencia exacta. Mi protocolo estaba mal. Lo corrijo.

---

‹ 7 operaciones de herramienta: Edit×4, Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 02:11:36 UTC

Ahora reescribo el protocolo de supersesión con orden total de locks y compensación transitiva:

---

‹ 5 operaciones de herramienta: Edit×4, Bash×1 ›

### [CLAUDE] · 2026-08-22 02:13:04 UTC

Ahora la especificación, con el orden de locks corregido:

---

‹ 8 operaciones de herramienta: Edit×6, Bash×2 ›

### [CLAUDE] · 2026-08-22 02:15:55 UTC

Aplicado. **24 hallazgos brutos → 17 confirmados tras refutación adversarial.** Tres eran críticos y uno era mío, grave.

## 🔴 El defecto que importa: mi protocolo tenía un deadlock en el caso nominal

Tres lentes independientes lo reprodujeron con la secuencia exacta. La supersesión tomaba el lock de la llave ajena **dentro** de la transacción de trabajo, invirtiendo el orden respecto de la petición reemplazada:

```
A (reemplazada)   toma  inventario(12,3)   → luego espera  llave A
B (reemplazante)  toma  llave A            → luego espera  inventario(12,3)
                          ↑ ciclo cerrado ↑
```

Dos órdenes de adquisición opuestos sobre los mismos dos recursos. Y lo peor no era el `40P01`: **la víctima la elegía el temporizador, no la recencia**. Si moría el reemplazante, su marca `SUPERSEDIDO` se revertía con el rollback, la petición vieja pasaba su punto de control y confirmaba — **ganaba el primer clic**, exactamente lo contrario de lo que pediste. Un auditor trazó además la deriva posterior: el cliente quedaba creyendo `base+0` con la BD en `base+1`, y el siguiente clic aplicaba `+3` sobre eso → `base+4` con tres pulsaciones.

**Corrección:** la marca `SUPERSEDIDO` se escribe en **conexión aparte con commit inmediato**, que nunca espera inventario y por tanto no puede participar en ningún ciclo. Dentro de toda transacción de trabajo el orden de locks queda invariante: `inventario → llave propia`.

## 🔴 La compensación no era transitiva

Con `A←B←C`: si `A` había confirmado y `B` era reemplazada tras heredar su deuda, nadie la asumía y `C` aplicaba de más. **Corrección:** columna `deuda` — cada llave graba lo que heredó, y su sucesora lo hereda si la abandonan.

## 🔴 Las transiciones de orden no registraban su autor

Una cancelación en `BORRADOR` no genera movimientos, así que su autor desaparecía por completo — hueco directo en tu punto 4. **Corrección:** `confirmado_por_usuario_id`, `enviado_por_usuario_id`, `cancelado_por_usuario_id` con `CHECK` de sello.

## Otras once correcciones

`TRUNCATE` vaciaba la bitácora "inmutable" (no dispara triggers de fila) · `ON DELETE CASCADE` permitía borrar órdenes en `BORRADOR` sin rastro · reactivar un catálogo **borraba** `desactivado_en` y su autor, destruyendo la historia de la baja · el índice único sobre `llave_supersede` estallaba con `23505` fuera de todo manejo · `RollbackAsync` sin protección suplantaba la excepción original y el `throw;` nunca corría · el refetch de la lista pisaba la intención pendiente causando doble aplicación · deshabilitar el control durante la mutación **anulaba la supersesión entera** (sin segundo clic no hay qué reemplazar) · `fn_sellar_baja_logica` aceptaba autor `NULL` · `fn_cancelar_orden` evadía la validación `WM014` por la puerta trasera · `P0002` escapaba crudo → 500 en vez de 404 · llaves `EN_PROCESO` huérfanas sin recuperación.

---

**Estado:** 13 tablas, 24 funciones, 27 triggers, 9 vistas, 41 pruebas de integración (7 de regresión de esta ronda, incluida `I33`: 200 cruces A/B sobre el mismo alcance con **cero `40P01`**). La sección **§4 · Manejo de errores y concurrencia** cierra el documento como pediste.

**Un punto donde debo ser honesto contigo.** El auditor de frontend señaló que *"cancelar la del primer clic" no se satisface literalmente*: con el debounce de 250 ms, dos clics rápidos producen **una sola petición** — la primera nunca llega a existir, así que no hay nada que cancelar. Cuando los clics sí van separados, la primera petición existe y sí se cancela (o se compensa). El resultado observable es el que buscas en ambos casos, pero el mecanismo no es siempre una cancelación. Si prefieres que **toda** pulsación emita petición y la anterior se cancele siempre — sin debounce —, es un cambio de una línea en el cliente, a costa de más tráfico y más renglones en la bitácora. Dime cuál prefieres.

Sigue pendiente lo mismo que antes: **el SQL no se ha ejecutado contra un Postgres real**. La auditoría es estática. `I0` (aplicar `0001` + `0002` sobre una instancia limpia) es lo primero de la Fase 2.

---
