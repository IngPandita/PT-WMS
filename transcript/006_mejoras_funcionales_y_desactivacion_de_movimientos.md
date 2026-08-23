# 006 · Mejoras funcionales y desactivación de movimientos

**Periodo:** 2026-08-22 06:30:44 UTC → 2026-08-22 07:16:46 UTC

**Intervenciones en este archivo:** 1 del usuario, 16 de Claude, 0 del sistema.

---

### [USUARIO] · 2026-08-22 06:30:44 UTC

Quiero continuar con el desarrollo de la aplicación e implementar las siguientes mejoras funcionales. No quiero únicamente cambios visuales en el frontend; revisa también backend, API, consultas y base de datos cuando sea necesario para que cada funcionalidad quede completamente implementada y consistente con la arquitectura actual.

## 1. Exportación de Inventario

Agregar un botón de **Exportar** en el apartado de Inventario.

El botón debe permitir exportar la información que actualmente se muestra en el inventario.

Consideraciones:

* Respeta los filtros actualmente aplicados al inventario al momento de exportar.
* Define un formato apropiado para la exportación, preferentemente CSV o Excel si la arquitectura actual lo permite.
* La exportación debe realizarse desde backend si el volumen de información puede ser considerable.
* No quiero cargar innecesariamente todos los registros en el navegador.
* Mantén los nombres de columnas claros y consistentes con la información mostrada en pantalla.
* Revisa permisos para garantizar que solamente usuarios autorizados puedan exportar información de inventario.

## 2. Búsqueda de productos dentro del modal de Orden

En el modal de creación/edición de una Orden, actualmente existe un selector de Producto.

Quiero modificarlo para que permita **escribir texto libre para buscar productos**.

El comportamiento esperado es:

1. El usuario comienza a escribir texto.
2. El frontend envía el texto de búsqueda al backend.
3. El backend realiza una búsqueda utilizando `LIKE`, conceptualmente:

```sql
WHERE campo_busqueda LIKE '%texto%'
```

4. Se muestran los productos que coincidan.
5. El usuario selecciona uno de los resultados.
6. El producto seleccionado queda asociado a la línea de la orden.

La búsqueda debe poder encontrar el producto por los campos que tengan sentido dentro del modelo actual, por ejemplo:

* SKU.
* Nombre del producto.
* Código u otro identificador relevante.

No hagas una búsqueda indiscriminada sobre todas las columnas si no es necesario.

Considera:

* Búsqueda parcial.
* Resultados limitados para evitar consultas excesivamente grandes.
* Debounce en frontend para no generar una petición por cada tecla.
* Manejo de estado de carga.
* Mensaje cuando no existan coincidencias.
* Manejo de errores.
* Evitar que una respuesta vieja de una búsqueda sobrescriba una búsqueda más reciente.
* La selección final debe utilizar el identificador real del producto y no el texto introducido por el usuario.

Si la arquitectura actual ya cuenta con un componente reutilizable de búsqueda/autocomplete, reutilízalo.

## 3. Modal para ajuste manual de Existencia

En el apartado de Inventario, agregar una acción para **ajustar manualmente la existencia de un producto**.

Debe abrirse un modal donde el usuario pueda introducir la cantidad.

El campo de cantidad debe ser:

* Numérico.
* Entero.
* Sin valores decimales.
* Validado tanto en frontend como en backend.
* No permitir valores inválidos según las reglas actuales del inventario.

Antes de implementar la lógica, determina si el concepto correcto es:

**A. Establecer existencia absoluta**

Ejemplo:

```text
Existencia actual: 10
Nueva existencia: 15
Resultado: 15
```

o:

**B. Aplicar un ajuste**

Ejemplo:

```text
Existencia actual: 10
Ajuste: +5
Resultado: 15
```

Utiliza la alternativa que sea consistente con el modelo actual de movimientos. Si el sistema ya maneja movimientos de inventario, preferentemente el ajuste manual debe generar un **movimiento de inventario auditable**, en lugar de modificar silenciosamente la existencia.

El movimiento debe conservar como mínimo:

* Producto/SKU.
* Cantidad afectada.
* Usuario que realizó el ajuste.
* Fecha y hora.
* Tipo de movimiento/ajuste.
* Identificador de operación.
* Información necesaria para auditoría.

Debe respetarse la lógica de transacciones, `try/catch`, `commit`, `rollback` e idempotencia que ya definimos anteriormente.

Un ajuste no debe poder aplicarse dos veces accidentalmente por doble clic, timeout, reintento o conexión lenta.

## 4. Filtros de Movimientos

Modificar los filtros existentes en el apartado de Movimientos.

Actualmente existe un filtro por ID. Quiero reemplazarlo por una búsqueda más útil:

### Filtro por Usuario

Permitir buscar/seleccionar un usuario para mostrar únicamente los movimientos realizados por ese usuario.

### Filtro por SKU

Permitir introducir o seleccionar un SKU para mostrar los movimientos correspondientes a ese producto.

### Filtro por fechas

Agregar:

* `fecha_inicio`
* `fecha_fin`

El rango predeterminado debe ser de **30 días**.

Es decir, al entrar al apartado de Movimientos, por defecto debe mostrar los movimientos correspondientes a los últimos 30 días.

Consideraciones:

* El filtro de usuario debe utilizar el identificador real del usuario.
* El filtro de SKU debe utilizar el SKU/producto real y no únicamente texto visual.
* Valida que `fecha_inicio <= fecha_fin`.
* Define correctamente si `fecha_fin` debe incluir todo ese día.
* Evita consultas innecesariamente costosas.
* Revisa índices de base de datos si son necesarios para que estos filtros sean eficientes.
* Conserva paginación si ya existe.
* La combinación de filtros debe funcionar simultáneamente.

Ejemplo:

```text
Usuario: Juan
SKU: ELEC-001
Fecha inicio: 01/08/2026
Fecha fin: 22/08/2026
```

debe devolver únicamente los movimientos que cumplan todas esas condiciones.

## 5. Nuevos KPI en el Tablero

Agregar dos nuevos indicadores/KPI al tablero.

### KPI 1 — Productos con mayor demanda

Mostrar los productos que tengan mayor demanda.

Determina la forma correcta de calcular "demanda" utilizando los datos y tipos de movimiento existentes.

No inventes una métrica arbitraria. Revisa primero cómo está modelado actualmente el movimiento de inventario y define la demanda con base en las operaciones que realmente representen consumo/salida/demanda.

El KPI debe mostrar como mínimo:

* Producto.
* SKU.
* Cantidad demandada.
* Posición/ranking.

Preferentemente mostrar un Top N configurable, por ejemplo Top 5 o Top 10.

### KPI 2 — Productos con existencia insuficiente

Agregar un KPI que identifique productos cuya existencia actual sea insuficiente.

Utiliza la información disponible en el modelo para determinar qué significa "existencia suficiente". Si ya existe un campo como:

* stock mínimo,
* existencia mínima,
* punto de reorden,
* nivel objetivo,

utiliza esa información.

La lógica debería ser conceptualmente similar a:

```text
existencia_actual < existencia_minima
```

Mostrar como mínimo:

* Producto.
* SKU.
* Existencia actual.
* Existencia mínima/requerida.
* Diferencia o cantidad faltante.

Si actualmente no existe un campo equivalente a existencia mínima, no inventes silenciosamente una regla. Identifica el faltante y propón la modificación necesaria al modelo de datos.

## 6. Revisión transversal

Antes de implementar, revisa cómo estas funcionalidades interactúan con el diseño existente.

En particular:

* Mantén las convenciones `cat_`, `tbl_` y `rel_` que ya definimos.
* Respeta la estructura actual de productos, inventario, órdenes y movimientos.
* Respeta soft-delete.
* Mantén la trazabilidad de usuario y fecha/hora.
* Mantén `id_operacion` e idempotencia para operaciones que modifiquen inventario.
* Las operaciones que modifiquen la DB deben utilizar transacciones y `rollback` ante errores.
* No permitas que un movimiento quede aplicado parcialmente.
* Considera concurrencia entre usuarios.
* No rompas funcionalidades existentes.
* Reutiliza componentes existentes cuando sea razonable.

## 7. Antes de terminar

No des por terminada una funcionalidad únicamente porque el frontend compile o porque el modal aparezca correctamente.

Para cada una de las funcionalidades:

1. Implementa frontend.
2. Implementa/modifica API y backend cuando sea necesario.
3. Modifica base de datos si es necesario.
4. Agrega validaciones.
5. Revisa permisos.
6. Agrega o actualiza pruebas.
7. Ejecuta las pruebas contra PostgreSQL real cuando corresponda.
8. Verifica casos de error y concurrencia relevantes.
9. Verifica que no existan regresiones.

Al finalizar, entrega un resumen indicando:

* Qué archivos/componentes modificaste.
* Qué migraciones de DB agregaste o modificaste.
* Qué endpoints agregaste/modificaste.
* Qué pruebas agregaste.
* Qué pruebas ejecutaste realmente.
* Qué quedó pendiente, si existe algo.
* Cualquier decisión de diseño que haya requerido interpretar información que no estaba definida.

Si encuentras una ambigüedad importante —especialmente respecto a la definición de demanda, existencia mínima o significado del ajuste manual— no la ocultes ni tomes una decisión arbitraria: indícala y utiliza la alternativa que mejor se ajuste al modelo existente, dejando la decisión documentada.

---

### [CLAUDE] · 2026-08-22 06:31:47 UTC

Antes de implementar necesito resolver tres ambigüedades **contra el modelo real**, no por intuición. Reviso qué hay.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 06:32:15 UTC

Ambigüedades resueltas contra el modelo. Escribo la migración con lo que falta.

---

‹ 2 operaciones de herramienta: Write×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 06:34:04 UTC

Ambos indicadores dan datos reales. Ahora el backend.

---

‹ 1 operaciones de herramienta: Write×1 ›

### [CLAUDE] · 2026-08-22 06:35:14 UTC

El usuario añade una funcionalidad que **choca de frente con un invariante que ya construí y verifiqué**: la bitácora es estrictamente de solo inserción. Lo resuelvo por la vía que el propio modelo dicta.

---

‹ 3 operaciones de herramienta: Write×2, Bash×1 ›

### [CLAUDE] · 2026-08-22 06:37:27 UTC

Todo lo sustantivo pasa. La prueba 9 falla por sintaxis mía: las variables de `psql` no interpolan dentro de bloques `$$`.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 06:37:59 UTC

**11/11 aserciones, `EXIT=0`.** La reversa funciona contra Postgres real. Ahora el backend de todo lo demás.

---

‹ 6 operaciones de herramienta: Write×4, Bash×2 ›

### [CLAUDE] · 2026-08-22 06:40:15 UTC

Ahora los endpoints y la compilación.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 06:43:58 UTC

Backend compilando. Verifico los nuevos endpoints contra Postgres real antes de tocar el frontend.

---

‹ 2 operaciones de herramienta: Write×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 06:49:22 UTC

161 pasan, 9 fallan. Cuatro son bugs de mis aserciones, dos son bugs reales. Diagnostico el de exportación.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 06:50:59 UTC

El export funciona; mi prueba fallaba porque el bloque de importación **borra el directorio temporal** antes. Corrijo eso, las aserciones mal escritas y un bug real: un JSON inválido daba 500 en vez de 400.

---

‹ 6 operaciones de herramienta: Bash×4, Edit×1, Write×1 ›

### [CLAUDE] · 2026-08-22 06:57:20 UTC

**170 aserciones E2E, 0 fallos.** Backend completo. Ahora el frontend.

---

‹ 9 operaciones de herramienta: Write×6, Bash×3 ›

### [CLAUDE] · 2026-08-22 07:02:38 UTC

TypeScript limpio. Añado los dos KPI al tablero.

---

‹ 2 operaciones de herramienta: Bash×2 ›

### [CLAUDE] · 2026-08-22 07:05:30 UTC

Frontend compila. Añado pruebas de componente para el autocompletado — es donde vive la regla de respuestas fuera de orden.

---

‹ 3 operaciones de herramienta: Bash×2, Write×1 ›

### [CLAUDE] · 2026-08-22 07:10:14 UTC

Sin regresiones: las 3 suites existentes pasan con las migraciones nuevas aplicadas. Integro la cuarta con la herramienta de edición.

---

‹ 2 operaciones de herramienta: Edit×1, Bash×1 ›

### [CLAUDE] · 2026-08-22 07:13:00 UTC

Todo verde. Cierro con `docker compose` completo para confirmar que las tres capas conviven con lo nuevo.

---

‹ 1 operaciones de herramienta: Bash×1 ›

### [CLAUDE] · 2026-08-22 07:16:46 UTC

Todo funcionando en el stack completo. **La aplicación está corriendo en http://localhost:5174** (`docker compose down` para pararla).

---

# Resumen de entrega

## ⚠️ Un conflicto de diseño que debo señalar primero

La funcionalidad de **desactivar movimientos** choca de frente con un invariante que ya estaba construido y verificado: la bitácora es **estrictamente de solo inserción** (`trg_..._inmutable` bloquea `UPDATE`/`DELETE`, `trg_..._sin_truncate` bloquea `TRUNCATE`, y `0003_permisos` revoca escritura al rol de la API).

Poner un `es_activo` mutable en la bitácora habría destruido justo la garantía que la hace confiable — y habría sido la "lógica paralela" que pediste evitar. **La resolución es la contable: no se borra ni se edita el asiento, se registra el asiento contrario.** Con eso el original queda intacto bit a bit, la existencia se recalcula sola porque la reversa pasa por el mismo trigger, `sum(delta_fisica)` sigue reconstruyendo `cantidad_fisica`, y "está desactivado" se **deriva** de la existencia de su reversa en vez de ser una bandera que alguien pueda cambiar.

**Tu propio ejemplo resultó ser un caso que debe rechazarse.** Con `+10`, `−3`, existencia 7: revertir el `+10` daría **−3**. Las unidades ya se consumieron. El sistema devuelve `WM002` y deja el inventario intacto, en lugar de corromperlo. Está probado explícitamente.

Impuse dos límites más, ambos deliberados: **no se revierte un movimiento de ORDEN** (revertir un embarque dejaría la orden diciendo `ENVIADA` sobre inventario que volvió — la vía es cancelar la orden), y **una reversa no se revierte** (desactivaría la corrección, no el error).

## Ambigüedades resueltas contra el modelo

| Ambigüedad | Resolución y por qué |
|---|---|
| **Demanda** | `EMBARQUE` — es el único tipo que produce `fn_enviar_orden`, o sea consumo real de un cliente. Excluí `SALIDA` (merma/corrección manual, no es demanda) y `RESERVA` (comprometida pero no consumida); la reserva vigente se reporta en columna aparte. Las reversas se descuentan |
| **Existencia mínima** | Ya existía: `tbl_inventario.cantidad_minima`. **No inventé campo.** El faltante se mide contra la **disponible**, no la física: lo reservado ya está comprometido. Expongo las tres cantidades para que la diferencia con `es_existencia_baja` (que usa física, como disparador clásico de reorden) sea visible y no una discrepancia silenciosa |
| **Ajuste manual: absoluto o delta** | **Absoluto** en la interfaz — es lo que hace un conteo físico. Pero la conversión a delta ocurre **en la base, bajo el row lock**: calcularla en el cliente sería una carrera con cualquier operador que mueva el producto entre la lectura y el envío. Genera un movimiento `AJUSTE` auditable, no una escritura silenciosa |
| **Permisos de exportación** | No hay auth en el alcance, pero `cat_usuarios.rol` sí existe. Sacar el catálogo con precios y valuación es distinto de mover una caja: lo limité a `SUPERVISOR` y `SISTEMA`. Es la política más conservadora que el modelo permite expresar sin inventar un sistema de permisos |

## Migraciones

**`0004_consultas_y_ajuste.sql`** — índice trigram sobre SKU (el existente es `text_pattern_ops`, solo sirve para prefijos, no para `%texto%`) · `producto_id`/`almacen_id` expuestos en `vw_movimientos_detalle` · índice `(tipo_movimiento, creado_en)` para la demanda · `fn_establecer_existencia` · `fn_productos_mayor_demanda(dias, limite)` · `vw_existencia_insuficiente` · índice parcial para el faltante.

**`0005_reversa_movimientos.sql`** — tipo `REVERSA` · `movimiento_revertido_id` con self-FK y **unicidad parcial** (barrera de motor contra doble desactivación) · `fn_revertir_movimiento` con la restricción a usuario 1 **en el motor** · vista con estado derivado · demanda que descuenta embarques revertidos.

## Endpoints

Nuevos: `GET /api/inventario/exportar` · `GET /api/productos/buscar` · `POST /api/inventario/establecer` · `GET /api/inventario/movimientos/{id}` · `POST /api/inventario/movimientos/{id}/desactivar`. Modificados: `GET /api/inventario/movimientos` (filtros por usuario, SKU, rango con 30 días por omisión, cursor) y `GET /api/indicadores` (parámetros `dias`/`topN`, dos KPI nuevos).

## Frontend

`BuscadorProductos` (autocomplete reutilizable, usado en órdenes **y** en el filtro de movimientos) · `ModalAjuste` · `ModalMovimiento` · botón Exportar · selección de fila con detalle · dos paneles KPI.

## Pruebas ejecutadas realmente

| Suite | Resultado |
|---|---|
| SQL — 4 suites contra PostgreSQL 16 | **45 aserciones, 0 fallos** |
| E2E HTTP — `tests/verificar_api.sh` | **170 aserciones, 0 fallos** |
| Componentes — Vitest | **16 pruebas, 0 fallos** |
| `docker compose up` desde cero + segunda corrida | ✅ |

Cubren tus nueve casos de reversa, incluidos: usuario ≠ 1 recibe **403 desde la API** (no solo botón oculto), doble clic idempotente, ya-desactivado rechazado, información histórica intacta, existencia compensada, y el invariante `sum(delta) = cantidad_fisica` sosteniéndose después de las reversas.

## Bugs reales que encontraron las pruebas

**Un `JSON` con decimal donde va entero daba 500 en vez de 400** — faltaba mapear `BadHttpRequestException`. Corregido. Y cuatro fallos más resultaron ser **de mis propias aserciones** (`grep -c` cuenta líneas y el JSON viene en una sola; el bloque de importación borraba el directorio temporal que la exportación necesitaba; una búsqueda de un solo carácter).

## Pendiente

Playwright · alta/edición de catálogos desde la interfaz (siguen de solo lectura) · README y `AI-USAGE.md`, que son entregables explícitos de la prueba técnica.

**Una limitación que declaro:** la exportación limita el CSV a los filtros pero no al `limite` de la pantalla — exporta *todo* lo que cumple el filtro, no solo los 100 visibles. Lo interpreté como lo deseable ("respeta los filtros"), pero si esperabas exactamente lo mostrado, es un cambio de una línea.

---
