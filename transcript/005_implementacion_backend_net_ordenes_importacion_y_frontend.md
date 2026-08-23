# 005 · Implementación: backend .NET, órdenes, importación y frontend

**Periodo:** 2026-08-22 04:01:43 UTC → 2026-08-22 06:16:38 UTC

**Intervenciones en este archivo:** 4 del usuario, 38 de Claude, 0 del sistema.

---

### [USUARIO] · 2026-08-22 04:01:43 UTC

Perfecto. Antes de continuar, quiero confirmar exactamente el estado actual de la Fase 2.

Por lo que describes, entiendo que ya no estamos únicamente en una auditoría estática y que las migraciones, pruebas y verificaciones mencionadas fueron ejecutadas realmente contra una instancia de PostgreSQL.

Antes de continuar con el siguiente punto de la Fase 2, necesito que me indiques claramente:

1. ¿La base de datos actual ya fue levantada sobre una instancia real de PostgreSQL?
2. ¿Las migraciones `0001`, `0002` y `0003` fueron ejecutadas exitosamente desde cero sobre una instancia limpia?
3. ¿La suite de pruebas de humo fue ejecutada realmente contra esa instancia?
4. ¿El script de verificación reproducible fue ejecutado y terminó exitosamente?
5. ¿Todos los escenarios críticos que mencionamos anteriormente fueron probados realmente?

   * Doble solicitud con el mismo `id_operacion`.
   * Reintento después de timeout.
   * Conexión lenta.
   * Dos usuarios modificando simultáneamente el mismo producto.
   * Rollback por error.
   * Importación parcial y reintento.
   * Soft-delete y trazabilidad.
   * Permisos de la bitácora.
6. ¿Existe actualmente algún error conocido, prueba pendiente o comportamiento que todavía no esté verificado?
7. ¿Existe alguna operación que todavía dependa de una protección temporal de frontend, como la ventana de 48 horas que mencionaste?
8. ¿Qué elementos concretos de la Fase 2 siguen pendientes?

Quiero que respondas con este formato:

**FASE 2 — ESTADO**

* Base de datos ejecutada: SÍ/NO
* Migraciones ejecutadas desde cero: SÍ/NO
* Suite de pruebas ejecutada: SÍ/NO
* Verificación reproducible ejecutada: SÍ/NO
* Pruebas de concurrencia: SÍ/NO
* Pruebas de idempotencia: SÍ/NO
* Pruebas de rollback: SÍ/NO
* Pruebas de importación: SÍ/NO
* Auditoría/permisos: SÍ/NO
* Pendientes: [lista concreta]

Después de esto, si no existen bloqueadores, continúa directamente con el siguiente punto pendiente de la Fase 2.

No quiero que vuelvas a ejecutar innecesariamente lo que ya está validado; quiero primero identificar exactamente dónde terminó la validación actual y desde ahí continuar.

---

### [CLAUDE] · 2026-08-22 04:02:22 UTC

Antes de responder necesito distinguir lo que **ejecuté** de lo que **describí**. Reviso exactamente qué cubre la suite actual.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 04:02:33 UTC

Coverage real identificada. **La totalidad del ciclo de órdenes, la importación, las vistas y toda la concurrencia nunca se ejecutaron.** Cierro esas brechas ahora.

---

‹ 4 operaciones de herramienta: Bash×3, Write×1 ›

### [CLAUDE] · 2026-08-22 04:04:27 UTC

Suite de órdenes completa: **EXIT=0**. Falta lo último y más difícil — **concurrencia real con sesiones paralelas**.

---

‹ 2 operaciones de herramienta: Write×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 04:06:33 UTC

Los tres resultados críticos pasan. Los dos fallos son **bugs de mi script de prueba**, no del sistema — `cliente_id=3` no existe y la captura de veredictos estaba mal. Los corrijo y repito.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 04:08:53 UTC

Test 3 falla por una carrera de escritura de archivo en Windows, no por la base. Lo reescribo para medir dentro de la propia base:

---

‹ 2 operaciones de herramienta: Edit×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 04:10:40 UTC

Todas pasan. Integro las tres suites en un solo comando y verifico de extremo a extremo.

---

‹ 3 operaciones de herramienta: Edit×2, Bash×1 ›

### [CLAUDE] · 2026-08-22 04:13:22 UTC

**Verificación completa: EXIT=0, 36 aserciones, 0 fallos.** No hay bloqueadores. Continúo con el siguiente pendiente del ciclo de base de datos: los datos iniciales.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 04:15:05 UTC

Un detalle: `productos_existencia_baja = 0`, así que el indicador de reposición del dashboard no tendría nada que mostrar. Lo corrijo.

---

‹ 5 operaciones de herramienta: Bash×3, Edit×2 ›

### [CLAUDE] · 2026-08-22 04:16:13 UTC

El contenedor se elimina antes de la sección de semilla — orden incorrecto en el script. Lo reordeno.

---

‹ 5 operaciones de herramienta: Edit×3, Read×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 04:19:26 UTC

**FASE 2 — ESTADO**

* Base de datos ejecutada: **SÍ** — PostgreSQL 16 en Docker
* Migraciones ejecutadas desde cero: **SÍ** — `0001`, `0002`, `0003` sobre instancia limpia con `ON_ERROR_STOP=1 --single-transaction`
* Suite de pruebas ejecutada: **SÍ** — 3 suites, 37 aserciones, 0 fallos
* Verificación reproducible ejecutada: **SÍ** — `db/pruebas/verificar.sh`, `EXIT=0`
* Pruebas de concurrencia: **SÍ** — 25 sesiones `psql` paralelas reales
* Pruebas de idempotencia: **SÍ** — secuencial y en paralelo
* Pruebas de rollback: **SÍ (a nivel de base de datos)**
* Pruebas de importación: **PARCIAL** — restricciones verificadas; orquestación .NET inexistente
* Auditoría/permisos: **SÍ**
* Pendientes: API .NET 8 · Frontend React · docker-compose · suites xUnit/Vitest/Playwright · plantilla de importación · README y `AI-USAGE.md` · instalar el barrido y asertar timeouts

---

## Corrección al reporte anterior

**Mi mensaje previo fue impreciso.** Dije "el escenario del doble clic con conexión lenta" pasaba, pero lo que se había ejecutado era solo la suite de idempotencia sobre ajustes de existencia. Al revisar la cobertura real encontré que **el ciclo completo de órdenes, la importación, las vistas y toda la concurrencia nunca se habían ejecutado** — 21 de 25 funciones sin ejercitar, incluidas `fn_confirmar_orden`, `fn_enviar_orden` y `fn_cancelar_orden`. Lo cerré antes de responderte.

## Escenario por escenario

| Escenario | Estado | Evidencia |
|---|---|---|
| Doble solicitud, mismo `id_operacion` | ✅ **SÍ** | Secuencial → `23505`, existencia `base+2`. **25 envíos simultáneos → 1 movimiento** |
| Reintento tras timeout | ⚠️ **Primitiva sí, flujo HTTP no** | `YA_COMPLETADA` devuelve la respuesta original sin re-aplicar. El timeout real necesita la API |
| Conexión lenta | ⚠️ **No como tal** | Lo que importa sí está probado: la garantía no depende del intervalo. Simular latencia exige la API |
| Dos usuarios simultáneos | ✅ **SÍ** | 25 operadores en paralelo sobre el mismo producto → exactamente `+25` y 25 movimientos |
| Rollback por error | ✅ **SÍ** | 3.ª escritura falla → orden revertida y existencia intacta |
| Importación parcial y reintento | ⚠️ **PARCIAL** | Lote único por operación, llaves derivadas por renglón, reintento de renglón rechazado. La reanudación y los `SAVEPOINT` viven en .NET |
| Soft-delete y trazabilidad | ✅ **SÍ** | 62 movimientos del operador dado de baja siguen resolviendo su nombre; no se puede borrar |
| Permisos de la bitácora | ✅ **SÍ** | `wms_api` recibe *permission denied* en `INSERT`; opera por la función |

Además, sin planearlo: **0 deadlocks** con 20 confirmaciones concurrentes de dos órdenes que declaran los mismos productos **en orden inverso** — es la prueba directa de que el `ORDER BY producto_id` hace su trabajo.

## Errores conocidos

**Ninguno abierto en el producto.** Encontré y corregí dos bugs, ambos **en mis scripts de prueba**, no en el sistema: un `cliente_id` inexistente, y una medición que escribía desde 25 procesos al mismo archivo del host — en Windows esa escritura no es atómica y falseaba el resultado. La rehice para medir dentro de la propia base.

## Protecciones residuales

1. **Ventana de 48 h** — se estrechó. `tbl_ordenes` ahora tiene `id_operacion` único, así que solo queda expuesta el **alta de producto**: sin movimiento y sin unicidad natural, su única barrera es `pk_tbl_operaciones`. Un reintento pasadas 48 h crearía un producto duplicado. Está declarado en la especificación.
2. **`pg_cron` no está en `postgres:16-alpine`**, así que el barrido no queda programado en el entorno de prueba. La función sí está probada; falta programarla (Supabase la trae).
3. **Los timeouts de sesión** se fijan con `ALTER ROLE` pero no se asertan.

Ninguna depende del frontend. El `debounce` y el `AbortController` quedaron como lo que son: UX.

---

## Lo que hice a continuación

El siguiente pendiente del ciclo de datos eran los **datos iniciales**, y ya está: [db/semilla.sql](db/semilla.sql), integrado al pipeline.

```
usuarios 5 (uno inactivo)   categorias 6   almacenes 3   clientes 8
productos 40   inventario 94   movimientos 225   ordenes 10   dias de serie 51
estados: BORRADOR 3 · CONFIRMADA 3 · ENVIADA 3 · CANCELADA 1
PASA  la semilla deja 8 alertas de reposicion para el dashboard
```

Dos detalles que resolví al construirla. Primero, **la bitácora ya no admite `INSERT` directo** — consecuencia de la corrección A5 —, así que las fechas escalonadas no se pueden fabricar insertando movimientos: la semilla conduce `fn_ajustar_existencia` desplazando temporalmente el `DEFAULT` de `creado_en`. Es la única vía que produce 51 días de serie temporal real **sin romper** el invariante `sum(delta_fisica) = cantidad_fisica`, que la propia semilla verifica y aborta si falla.

Segundo, la primera versión dejaba `productos_existencia_baja = 0` — el indicador de reposición del dashboard habría salido vacío en la demo. Ahora deja 8 filas bajo su umbral, y el pipeline **falla** si ese contador vuelve a cero.

**La capa de base de datos está cerrada y verificada.** El siguiente pendiente es la API .NET 8 — y ahí el trabajo tiene una propiedad útil: las primitivas atómicas ya existen y están probadas, así que los handlers son orquestación sobre contratos que no pueden violarse. ¿Arranco por ella?

---

### [USUARIO] · 2026-08-22 04:32:07 UTC

Si continua

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 04:32:39 UTC

Sin SDK en el host, pero con Docker puedo compilar y **ejecutar** dentro del contenedor oficial — mantengo el estándar de verificar por ejecución. Confirmo primero.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 04:33:06 UTC

Compilador listo. Escribo la solución — empiezo por dominio y aplicación.

---

‹ 3 operaciones de herramienta: Bash×3 ›

### [CLAUDE] · 2026-08-22 04:34:57 UTC

Vuelvo a la herramienta de escritura directa — el shell ya me costó tiempo con comillas en esta sesión.

---

‹ 14 operaciones de herramienta: Write×12, Bash×2 ›

### [CLAUDE] · 2026-08-22 04:40:47 UTC

Compila. Corrijo la advertencia y ejecuto las pruebas.

---

‹ 2 operaciones de herramienta: Write×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 04:42:42 UTC

Build limpio, **36/36 pruebas unitarias**. Ahora lo que realmente faltaba: probar el escenario del doble clic **sobre HTTP**.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 04:46:21 UTC

El escenario central pasa sobre HTTP. Cuatro fallos reales que investigo:

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 04:48:10 UTC

Causa real: Postgres devuelve los alias en minúsculas y `timestamptz` mapea a `DateTime`, no a `DateTimeOffset`. Corrijo el mapeo.

---

‹ 4 operaciones de herramienta: Write×2, Bash×2 ›

### [CLAUDE] · 2026-08-22 04:51:07 UTC

**Las 30 aserciones E2E pasan sobre HTTP.** Los escenarios que declaré no verificables ya no lo son. Actualizo la especificación.

---

‹ 2 operaciones de herramienta: Edit×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 04:51:54 UTC

API .NET 8 en pie y verificada. **103 aserciones en total, 0 fallos.**

## Lo más importante: cerré los escenarios que declaré no verificables

Sin SDK en la máquina, compilé y ejecuté dentro del contenedor oficial de .NET 8 para no bajar el estándar de verificar por ejecución. `tests/verificar_api.sh` levanta Postgres + migraciones + semilla + la API y ejerce los endpoints con `curl`:

```
=== 1) EL ESCENARIO DEL REQUERIMIENTO: modal, conexion lenta, segundo clic ===
PASA  primer clic responde 200          PASA  primer clic NO es reenvio
PASA  segundo clic responde 200         PASA  segundo clic SI es reenvio
PASA  existencia subio 2, no 4          PASA  un solo movimiento para esa operacion

=== 2) REINTENTO TRAS TIMEOUT: el cliente corta, reenvia el MISMO id ===
PASA  el reenvio responde 200   PASA  el efecto total es +5, no +10   PASA  un solo movimiento

=== 7) 10 ENVIOS SIMULTANEOS DEL MISMO ID SOBRE HTTP ===
PASA  efecto unico pese a 10 peticiones paralelas   PASA  un solo movimiento
```

El caso 2 es el que llevaba tres iteraciones sin poder probarse: `curl --max-time 0.05` corta la conexión mientras el backend procesa, y el reenvío con el **mismo** `id_operacion` devuelve la respuesta original sin volver a sumar. Ya no es una afirmación de diseño.

## Tres decisiones que el código hace explícitas

**El hash ignora el motivo — y hay una prueba que lo fija.** `HuellaPeticion` declara los campos de la intención por ruta y falla si una ruta no los declara. La prueba `Editar_el_motivo_NO_cambia_la_huella` documenta por qué: si el motivo entrara al hash, corregir su texto entre reenvíos daría `WM015` permanente, el usuario cerraría el modal y acuñaría un id nuevo — que **sí** se aplicaría dos veces. Verificado también sobre HTTP: motivo editado → 200; cantidad cambiada → 409/`WM015`.

**El `23505` del índice de barrera se traduce como éxito de la protección**, no como error interno: el middleware detecta `ux_tbl_movimientos_inventario__operacion` y responde 409 apuntando a `/api/inventario/movimientos?idOperacion=`, que es la ruta segura tras un conflicto.

**Polly reintenta con el mismo `id_operacion`.** Está comentado en el código porque es contraintuitivo: acuñar uno nuevo en el reintento sería exactamente el bug que produce la doble aplicación. Es seguro porque el intento fallido dejó la operación en `FALLIDO` y la reserva la readmite.

## Dos correcciones que salieron de ejecutar

**El tablero y los movimientos devolvían 500.** Postgres devuelve los alias en minúsculas y `timestamptz` mapea a `DateTime`, no a `DateTimeOffset`; Dapper no podía materializar los records. Quité los alias, activé `MatchNamesWithUnderscores` y ajusté los tipos. Añadí también casts explícitos (`@Texto::text`) para que un parámetro nulo dentro de una concatenación no rompa la inferencia de tipos.

**Una prueba mía estaba mal planteada.** Esperaba `WM016` cuando otro operador enviaba el mismo id de cliente. Pero el prefijo lo antepone el **servidor**, así que dos operadores nunca colisionan: el resultado correcto es que cada uno aplique su propia operación. Cambié la aserción para verificar el aislamiento — dos movimientos distintos, no uno — que es lo que realmente importa. `WM016` sigue siendo defensa en profundidad a nivel de motor, ya cubierta en la suite SQL.

## Estado

| Capa | Cobertura |
|---|---|
| Unitarias (xUnit + FluentAssertions) | **36** — SKU contra regla dinámica, huella canónica, mapeo SQLSTATE→HTTP, validadores |
| SQL (3 suites + semilla) | **37** |
| E2E HTTP | **30** |

**Pendiente de Fase 2:** endpoints de órdenes y catálogos · importación con reanudación por renglón · frontend React · `docker-compose` · Playwright/Vitest · README y `AI-USAGE.md`.

La ruta de inventario está completa de extremo a extremo. Los endpoints de órdenes son el siguiente paso natural: `fn_confirmar_orden`, `fn_enviar_orden` y `fn_cancelar_orden` ya están probadas, así que son el mismo patrón de tres fases sobre primitivas verificadas. ¿Sigo con ellos?

---

### [USUARIO] · 2026-08-22 05:11:40 UTC

Si continua

---

### [CLAUDE] · 2026-08-22 05:12:05 UTC

Continúo con órdenes. Primero extraigo el patrón de tres fases para no repetirlo cuatro veces.

---

‹ 9 operaciones de herramienta: Write×7, Bash×2 ›

### [CLAUDE] · 2026-08-22 05:16:28 UTC

El parche automático se enredó. Reescribo el archivo limpio.

---

‹ 2 operaciones de herramienta: Write×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 05:18:18 UTC

Build limpio. Extiendo la verificación E2E con el ciclo completo de órdenes.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 05:21:26 UTC

Un fallo, y es de mi prueba: el helper `accion` envía siempre `X-Usuario-Id: 2`, así que canceló el usuario 2 — el sistema registró correctamente. Lo parametrizo para que la aserción sea más fuerte.

---

‹ 7 operaciones de herramienta: Bash×5, Write×1, Edit×1 ›

### [CLAUDE] · 2026-08-22 05:26:13 UTC

Ciclo de órdenes completo y verificado. **153 aserciones en total, 0 fallos** (36 unitarias + 37 SQL + 80 E2E).

## Refactor primero: el patrón de tres fases en un solo lugar

Antes de escribir cuatro manejadores nuevos extraje `EjecutorIdempotente`. La razón está en el comentario del código: *repetir las fases en cada manejador invitaba a que uno se saltara un paso, y el paso que se olvida siempre es el que rompe la garantía*. Ahora cada manejador solo declara **cuál es la intención** y **cuál el trabajo**; el ejecutor pone reserva, transacción, sellado, rollback y cierre. Refactoricé también `AjustarExistencia` para que no quedaran dos copias.

Confirmar, enviar y cancelar comparten además una clase base: son la misma forma con distinta primitiva.

## Lo que la verificación E2E demuestra ahora

```
=== 12) REENVIO DEL ALTA: no debe crear una segunda orden ===
PASA  el reenvio del alta responde 200      PASA  devuelve el MISMO folio
PASA  hay una sola orden con ese id_operacion (= 1)

=== 14) CONFIRMAR: reserva sin tocar la existencia fisica ===
PASA  la reserva subio 4        PASA  la existencia fisica NO cambio

=== 15) REENVIO DE LA CONFIRMACION: sin doble reserva ===
PASA  la reserva NO se duplico

=== 16) ENVIAR: descuenta fisico y libera reserva ===
PASA  la existencia fisica bajo 4   PASA  la reserva se libero
PASA  el embarque quedo en la bitacora (= 2)

=== 19) EXISTENCIA INSUFICIENTE AL CONFIRMAR ===
PASA  confirmar sin existencia (= 422)   PASA  codigo WM002
PASA  la orden sigue en BORRADOR tras el rollback
```

El alta de orden tiene **barrera de motor propia**: `tbl_ordenes.id_operacion` es único, así que un reenvío no puede crear una segunda orden ni aunque el sobre de idempotencia fallara. El caso 19 es el rollback visto desde HTTP: la confirmación falla, la orden vuelve a `BORRADOR` y nada queda a medias.

## Un fallo que resultó ser de la prueba, no del sistema

La aserción "quedó registrado quién canceló" esperaba el usuario 3 y obtuvo el 2. Revisé: mi helper `accion` mandaba `X-Usuario-Id: 2` fijo, así que **canceló el usuario 2 y el sistema lo registró correctamente**. Parametricé el helper y aproveché para hacer la aserción más fuerte de lo que era: ahora el usuario 3 crea la orden, el 4 la cancela, y se verifican tres cosas por separado — `creado_por_usuario_id=3`, `cancelado_por_usuario_id=4`, y que los movimientos de `LIBERACION` quedaron atribuidos al 4. Eso sí prueba lo que pide el punto 4 de trazabilidad; la versión anterior no lo hacía.

## Detalles de diseño que vale la pena señalar

**El motivo de cancelación viaja como parámetro pero no entra en la huella**, igual que el del ajuste — misma regla, mismo motivo: corregir su texto entre reenvíos no debe convertir la operación en otra.

**Las partidas entran a la huella como agregado ordenado** (`HuellaPartidas`): cambiar una cantidad es otra intención, pero reordenar la captura no.

**Los catálogos usan lista blanca.** El nombre del recurso nunca se concatena crudo al SQL; un recurso desconocido da 404, no un error de sintaxis.

**Las lecturas se apoyan en las vistas.** La API no reconstruye el localizador `SKU@ALM-XXX` ni el estado derivado de un movimiento: viven en una sola definición, no en dos.

Un tropiezo técnico: C# no admite `dynamic` como argumento de tipo de una interfaz implementada, así que los catálogos e indicadores devuelven un `Fila : Dictionary<string, object?>` — serializa a JSON exactamente igual.

## Estado

**13 endpoints** funcionando: inventario (tablero, movimientos, ajuste), órdenes (alta, partidas, confirmar, enviar, cancelar, listado), catálogos, SKU e indicadores del dashboard.

**Pendiente de Fase 2:** importación con plantilla y reanudación por renglón · frontend React · `docker-compose` · Playwright/Vitest · README y `AI-USAGE.md`.

La importación es lo único de backend que queda, y es la pieza con más reglas propias — reanudación desde el primer renglón no-`OK`, un `SAVEPOINT` por renglón, id derivado del contenido del archivo. ¿Sigo con ella, o prefieres que arranque el frontend para tener algo navegable antes?

---

### [USUARIO] · 2026-08-22 05:28:30 UTC

Sigue con eso y una vez terminado arranca el Front

---

### [CLAUDE] · 2026-08-22 05:28:59 UTC

Empiezo por la importación. Primero cierro un hueco que la auditoría marcó y que la importación va a tocar: el sello de baja no se aplica en `INSERT`.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 05:29:34 UTC

Ahora la importación. Es la única operación cuyo trabajo se confirma por partes, así que lleva reglas propias.

---

‹ 4 operaciones de herramienta: Write×3, Bash×1 ›

### [CLAUDE] · 2026-08-22 05:32:43 UTC

`Application` no debe depender del driver. Uso `DbException.SqlState` (estándar en .NET 8) y desambiguo por semántica, no por el texto del error.

---

‹ 2 operaciones de herramienta: Bash×2 ›

### [CLAUDE] · 2026-08-22 05:35:52 UTC

Ahora verifico la importación de extremo a extremo, incluido el caso difícil: reimportar el mismo archivo.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 05:40:46 UTC

El `000` es de curl en Windows: `MSYS_NO_PATHCONV` deja pasar rutas POSIX que el binario nativo no resuelve. Uso rutas relativas.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 05:41:04 UTC

La importación funciona: reimportar deja la existencia en **5, no 10**. Corrijo las rutas en el script de prueba.

---

‹ 2 operaciones de herramienta: Bash×2 ›

### [CLAUDE] · 2026-08-22 05:45:41 UTC

Dos cosas: `campo()` toma la última coincidencia (test), y un **bug real** — la ruta de encabezado inválido reporta `TotalRenglones=0` mientras registra 1 renglón de error, violando `ck_..__conteos`.

---

‹ 3 operaciones de herramienta: Bash×3 ›

### [CLAUDE] · 2026-08-22 05:50:50 UTC

**Importación completa: 111 aserciones E2E, 0 fallos.** Reimportar el mismo archivo reanuda el lote y no duplica nada. Arranco el frontend.

---

‹ 17 operaciones de herramienta: Write×11, Bash×6 ›

### [CLAUDE] · 2026-08-22 06:02:11 UTC

Compila. Ahora las pruebas de los componentes críticos — el stepper es donde vive la disciplina del `id_operacion`.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 06:04:42 UTC

9/9 pruebas de componente. Ahora cierro con `docker compose` — que es a la vez entregable pendiente y la prueba de que las tres capas conviven.

---

‹ 3 operaciones de herramienta: Bash×3 ›

### [CLAUDE] · 2026-08-22 06:12:31 UTC

Los puertos 8080/5432 los ocupan contenedores tuyos (`miniwms-*`, Supabase local) que **no voy a tocar**. Muevo los míos.

---

‹ 2 operaciones de herramienta: Bash×2 ›

### [CLAUDE] · 2026-08-22 06:13:34 UTC

El volumen persiste, así que la segunda corrida re-aplica DDL no idempotente. Eso rompería `docker compose up` para cualquiera. Añado un registro de migraciones.

---

‹ 4 operaciones de herramienta: Bash×3, Write×1 ›

### [CLAUDE] · 2026-08-22 06:15:48 UTC

Todo en pie. Actualizo el estado en la especificación.

---

‹ 2 operaciones de herramienta: Edit×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 06:16:38 UTC

Importación y frontend terminados. **El sistema está corriendo ahora mismo en http://localhost:5174** — para pararlo, `docker compose down`.

## Importación: 111 aserciones E2E, 0 fallos

El caso que importa, verificado sobre HTTP:

```
=== 24) REIMPORTAR EL MISMO ARCHIVO: no debe duplicar existencias ===
PASA  reanuda el MISMO lote          PASA  se marca como reanudacion
PASA  la existencia NO se duplico    PASA  no se creo un segundo lote
PASA  no se duplicaron los productos
```

Tres reglas propias, porque es la única operación cuyo trabajo se confirma por partes:

**El `id_operacion` del lote se deriva del contenido del archivo**, no del instante en que se eligió. Si se acuñara al abrir el selector, quien reintenta tras un corte reseleccionaría el archivo, acuñaría un id nuevo, y las llaves por renglón frescas no colisionarían: los 3 000 renglones se aplicarían otra vez.

**Cada renglón corre bajo su propio `SAVEPOINT`.** Un `23505` significa "este renglón ya se aplicó": se retrocede solo ese renglón y el chunk continúa. Sin el savepoint, ese error mataría los 500 renglones del chunk y la reimportación no avanzaría nunca.

**Desambiguo el `23505` por semántica, no por el nombre del constraint.** `Application` no debe conocer el driver, así que uso `DbException.SqlState` (estándar en .NET 8) y luego consulto si ya existe el movimiento de esa llave. Es más robusto que comparar cadenas y mantiene la capa limpia.

Dos defectos que encontró la prueba: la ruta de encabezado inválido reportaba `TotalRenglones = 0` mientras registraba un renglón de error, violando `ck_..__conteos` → 500. Y en la BD, el sello de baja no se aplicaba en `INSERT`, así que importar un producto ya inactivo era imposible — extendí el trigger a `INSERT`.

## Frontend

Seis pantallas: tablero con Recharts, inventario con ajuste rápido, órdenes con su ciclo, movimientos, importación y catálogos. Paleta sobria de un solo acento, estados vacíos, skeletons y toasts.

**Las 9 pruebas de componente fijan el contrato del `id_operacion`:**

```
✓ el boton NUNCA se deshabilita: sin segundo clic no hay nada que reemplace al primero
✓ acumula la intencion y emite UNA sola peticion con el total
✓ tras un exito, la siguiente intencion acuna un id NUEVO
✓ tras un fallo, el reintento CONSERVA el mismo id: reintentar es seguro
✓ un refetch actualiza la base sin descartar la intencion pendiente
```

`baseConfirmada` y `deltaIntencion` viven separados a propósito: si un refetch escribiera la suma sobre la base, el siguiente envío aplicaría el delta dos veces. La quinta prueba simula justo eso — otro operador mueve el producto a 130 mientras hay `+1` pendiente — y verifica que salga 131.

## Docker

`docker compose up` verificado desde volumen limpio **y en segunda corrida**. Encontré que la segunda fallaba: el DDL no es idempotente y el volumen persiste. Añadí un registro de migraciones, así que ahora:

```
omitida  0001_esquema.sql (ya aplicada)   ...   la semilla ya estaba aplicada (5 operadores)
```

Y la garantía se sostiene atravesando **nginx → API → Postgres**: el reenvío del mismo id devuelve `"fueReenvio":true` con la existencia sin cambiar.

**Una nota:** los puertos 8080 y 5432 los ocupan contenedores tuyos (`miniwms-*` y Supabase local). No los toqué; mis servicios usan 8081 y 5174, ajustables con `PUERTO_API` y `PUERTO_WEB`.

## Estado

| Capa | Verificación |
|---|---|
| SQL (6 archivos) | 37 aserciones · 3 suites + semilla |
| C# (41 archivos) | 36 unitarias + 111 E2E |
| TS/TSX (17 archivos) | build limpio + 9 de componente |
| Docker | `up` limpio y re-ejecutable |

**Pendiente:** Playwright (E2E de navegador) · alta y edición de catálogos desde la interfaz — hoy son de solo lectura, y la especificación pide administrarlos · README y `AI-USAGE.md`, que son entregables explícitos de la prueba.

Sugiero cerrar con **README y `AI-USAGE.md`** antes que Playwright: son requisito de entrega y sin ellos el repositorio está incompleto aunque el sistema funcione. ¿Sigo por ahí?

---
