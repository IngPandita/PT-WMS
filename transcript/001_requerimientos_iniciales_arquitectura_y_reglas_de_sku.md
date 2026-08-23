# 001 · Requerimientos iniciales, arquitectura y reglas de SKU

**Periodo:** 2026-08-21 22:46:08 UTC → 2026-08-21 23:10:06 UTC

**Intervenciones en este archivo:** 2 del usuario, 3 de Claude, 0 del sistema.

---

### [USUARIO] · 2026-08-21 22:46:08 UTC

Actúa como un Orquestador de Sistemas de IA Senior de nivel Staff. Vamos a reconstruir un Mini WMS + Órdenes bajo una arquitectura Multi-Agente Estricta utilizando el siguiente stack tecnológico: Backend en .NET 8 (Web API con C#), Frontend en React (TypeScript, Vite, Tailwind CSS y Shadcn UI), y Base de Datos gestionada en Supabase (PostgreSQL).

*Nota de Alcance Importante:* Al ser una prueba técnica, NO requerimos flujos de autenticación de usuarios ni Row Level Security (RLS) basado en usuarios. El foco absoluto del sistema debe estar en la consistencia de los catálogos, las relaciones relacionales, el control de inventario y la mitigación de la concurrencia.

---

### 1. NUEVOS REQUERIMIENTOS CRÍTICOS DE ARQUITECTURA Y NEGOCIO

Para este diseño, debes implementar obligatoriamente las siguientes especificaciones sobre la base del WMS:

#### A. Catálogo Estricto de Categorías
- La categoría ya no es un campo de texto plano (`string`) dentro del producto. Debe existir una tabla e interfaz independiente para administrar un Catálogo de Categorías (ID, Nombre, Descripción, Código de Categoría para SKU).
- En la interfaz de configuración del producto, la categoría debe seleccionarse mediante un componente combobox/select alimentado dinámicamente desde este catálogo.

#### B. Motor de SKUs Dinámicos Inteligentes
- **Estructura Parametrizada:** El SKU de un producto debe ser generado o validado de forma dinámica combinando atributos lógicos del negocio: `[CÓDIGO_CATEGORÍA]-[CÓDIGO_PRODUCTO]-[VARIANTE/LOTE]`.
- **Dinámica de Almacenes:** Cada almacén debe poseer un identificador o código único e inequívoco de longitud fija (ej: `ALM-NTE`, `ALM-SUR`) administrable, el cual formará parte de la trazabilidad y la composición o validación visual del inventario de los productos asociados.
- El sistema debe contar con un servicio de parsing en el backend (.NET 8) que descomponga el SKU para validar su estructura por medio de expresiones regulares (Regex) dinámicas antes de procesar inserciones o importaciones masivas.

#### C. Control de Stock Express desde la Interfaz (Quick-Adjust)
- La plataforma de frontend debe incluir controles directos (botones de incremento/decremento rápido o un modal simplificado tipo popover de Shadcn) dentro de la misma lista o vista de inventarios para agregar o remover cantidades de un producto en un almacén específico de manera inmediata.
- Cada clic en estos botones debe disparar un comando idempotente hacia el API de .NET 8 (pasando un `X-Idempotency-Key` único por transacción) para registrar la entrada/salida y generar el correspondiente registro en el historial de movimientos de inventario de manera atómica.

---

### 2. ACTIVACIÓN DE CAPACIDADES Y SKILLS ESPECIALIZADAS

#### A. Skill: Frontend Design (Anthropic & Linear Style)
- **Visual Identity:** Interfaces ultra-limpias, tipografías nítidas, contrastes balanceados y espaciados consistentes inspirados en Linear.
- **Componentes Avanzados:** Integración nativa de `@shadcn/ui`. Obligatorio el uso de estados vacíos (Empty States), esqueletos de carga (Skeleton Loaders) y toasts dinámicos para notificar si un ajuste rápido de inventario fue exitoso o falló debido a concurrencia.
- **Flujos Dedicados:** Vistas dedicadas para la configuración del catálogo de categorías, asignación/creación de almacenes y el dashboard interactivo utilizando Recharts.

#### B. Skill: .NET 8 Enterprise Architecture
- **Patrones:** Clean Architecture o Vertical Slice Architecture junto con el patrón CQRS mediante MediatR para desacoplar lecturas de escrituras.
- **Resiliencia y Concurrencia:** Implementar políticas de reintento de bajo nivel y Backoff Exponencial utilizando `Polly`. Estrategia estricta contra Race Conditions en el controlador de inventario usando control de concurrencia optimista (columna `version_ecc` / tokens de versión) o bloqueos pesimistas en base de datos.

#### C. Skill: Supabase & Postgres Advanced DBA
- **Consistencia Relacional Extrema:** Integridad referencial estricta (FKs entre productos, categorías, almacenes, inventarios, órdenes y movimientos).
- **Automatización en BD:** Triggers en PL/pgSQL para poblar de forma inmediata la tabla de `movimientos_historicos` de inventario ante inserciones, órdenes de venta confirmadas o ajustes manuales express realizados desde la UI.

#### D. Skill: Testing Automatizado E2E & Unitario
- **Backend:** Suite de pruebas con xUnit, FluentAssertions y NSubstitute enfocadas en validar las reglas del SKU dinámico y el bloqueo de stock negativo.
- **Frontend / Integration:** Pruebas unitarias de componentes críticos con Vitest y escenarios E2E del ciclo de vida completo de una orden utilizando Cypress o Playwright.

---

### 3. PROTOCOLO MULTI-AGENTE (Simulación de Roles)

Cada respuesta o bloque de código generado debe ser precedido por la etiqueta del agente que lo ejecuta:

- **[🤖 AGENTE ARCHITECT / AUDITOR]:** Valida que no existan ambigüedades, audita el control de concurrencia y la idempotencia (`X-Idempotency-Key`) en los ajustes rápidos de inventario. Aprueba o rechaza antes de escribir código definitivo.
- **[💻 AGENTE DB-DBA]:** Diseña el esquema SQL relacional para Supabase (tablas de categorías, productos, almacenes, stock, movimientos, órdenes), índices compuestos para búsquedas rápidas por SKU/Almacén, y triggers de automatización.
- **[💻 AGENTE BACKEND]:** Desarrolla la API en .NET 8, los validadores del SKU dinámico, los endpoints de ajuste de inventario express y la lógica para la carga masiva mediante plantillas.
- **[💻 AGENTE FRONTEND]:** Desarrolla la SPA en React, el sistema de diseño limpio con Shadcn, las pantallas de catálogos (Categorías/Almacenes) y las acciones rápidas de incremento de stock en la tabla de inventario.
- **[🧪 AGENTE QA / TESTING]:** Diseña y escribe los casos de prueba automatizados para asegurar que dos clics simultáneos en el botón de agregar cantidad no rompan la consistencia del stock.

---

### 4. FLUJO DE TRABAJO IMPERATIVO POR ITERACIONES

Seguiremos un proceso estricto de 3 fases para cada funcionalidad:
1. **Fase de Diseño y Auditoría:** El `AGENTE ARCHITECT` y el `AGENTE DB-DBA` presentan el modelo relacional adaptado a catálogos y resuelven las ambigüedades del SKU dinámico.
2. **Fase de Codificación Limpia:** El `AGENTE BACKEND` y `AGENTE FRONTEND` generan código modular, tipado y documentado con control de operaciones concurrentes.
3. **Fase de Verificación Explicita:** El `AGENTE QA` genera la prueba automatizada que valide el flujo sin fallos.

Comienza presentándote,  lee el archivo de Prueba Tecnica, inicia el entorno multi-agente y proponiendo la estructura relacional detallada de la Base de Datos en PostgreSQL (Supabase) que soporte las categorías como catálogo, los códigos de almacén y las llaves compuestas de inventario. ¡No escribas código de la aplicación aún, preparemos la base de datos y la arquitectura primero!

---

‹ 9 operaciones de herramienta: Bash×7, Skill×2 ›

### [CLAUDE] · 2026-08-21 22:52:31 UTC

# 🧠 Orquestador de Sistemas de IA — Sesión iniciada

Soy el **Orquestador Staff** de esta sesión. Coordino cinco agentes especializados bajo un protocolo estricto de tres fases (Diseño/Auditoría → Codificación → Verificación), y mi función es que **ningún agente escriba una línea de código antes de que las ambigüedades estén cerradas por escrito**.

**Clasificación del trabajo (obligatoria antes de arrancar):** este es un proyecto **arquitectónico** — repo vacío (solo existe el enunciado), múltiples subsistemas nuevos, decisiones de interfaz que otros componentes van a heredar. Por lo tanto seguimos el camino completo: contexto → ambigüedades → 2-3 enfoques → diseño por secciones → spec escrito → plan de implementación. **No se escribe código de aplicación en esta iteración.**

**Estado del entorno multi-agente:**

| Agente | Estado | Asignación en Iteración 1 |
|---|---|---|
| 🤖 ARCHITECT / AUDITOR | 🟢 Activo | Auditoría de ambigüedades + veredicto de concurrencia/idempotencia |
| 💻 DB-DBA | 🟢 Activo | Modelo relacional PostgreSQL/Supabase |
| 💻 BACKEND | ⏸️ En espera | Bloqueado hasta aprobación del modelo |
| 💻 FRONTEND | ⏸️ En espera | Bloqueado hasta aprobación de contratos API |
| 🧪 QA / TESTING | 🟡 Observando | Redactando matriz de escenarios de concurrencia |

**Contexto leído:** [Prueba Técnica - Mini WMS + Órdenes.md](Prueba%20Técnica%20-%20Mini%20WMS%20+%20Órdenes.md) — 6.3 KB, procesado completo. Directorio de trabajo vacío (sin git inicializado aún).

---

## [🤖 AGENTE ARCHITECT / AUDITOR] — Auditoría de ambigüedades

El enunciado declara explícitamente que las ambigüedades **son intencionales** y que se evalúa la capacidad de identificarlas. Detecté 12. Nueve las resuelvo por criterio técnico; **tres más una decisión de arquitectura** requieren tu ratificación porque cambian materialmente el modelo de datos.

### Resueltas por criterio (documentadas como supuestos)

| # | Ambigüedad detectada | Resolución del AUDITOR |
|---|---|---|
| A1 | "SKU identifica inequívocamente" pero no define formato | SKU es **columna derivada** (`GENERATED STORED`), no capturable a mano. Imposible desincronizarlo de sus componentes. |
| A2 | ¿Se puede borrar un producto/categoría con inventario? | **No.** `ON DELETE RESTRICT` en toda relación transaccional. Baja lógica vía `status`. Un WMS nunca pierde trazabilidad. |
| A3 | ¿Precio del producto o precio de la orden? | La partida **congela** `unit_price`, `sku_snapshot`, `name_snapshot`. Cambiar el catálogo no reescribe historia. |
| A4 | ¿Total de la orden calculado o almacenado? | `line_total` es generado por partida; `orders.total_amount` lo mantiene un trigger. Nunca lo calcula el cliente. |
| A5 | Moneda no especificada | **Supuesto: monotoneda (MXN).** `numeric(14,2)`, jamás `float`. Multimoneda declarado fuera de alcance. |
| A6 | Cantidades: ¿enteras o fraccionarias? | **Enteras** (piezas). `integer`, no `numeric`. Simplifica las pruebas de concurrencia y es defendible en un WMS de piezas. |
| A7 | "Registros duplicados" en importación sin política definida | Modo explícito por lote: `CREATE_ONLY` (duplicado = error de fila) o `UPSERT` (duplicado = actualiza). **Éxito parcial por fila**, no todo-o-nada. |
| A8 | "Información suficiente del resultado" de importación | Persistimos `import_batches` + `import_batch_rows` con `raw_payload` y `error_code` por renglón. El resultado es consultable después, no solo un toast. |
| A9 | ¿Reintentos requieren tratamiento especial? | **Sí, obligatorio.** `X-Idempotency-Key` con huella del payload: misma clave + mismo cuerpo → respuesta original; misma clave + cuerpo distinto → `409`. TTL 48 h. |

### 🚨 Hallazgo crítico de auditoría — riesgo de contradicción en el requerimiento B

> *"Cada almacén debe poseer un código único… el cual formará parte de la trazabilidad y **la composición o validación visual** del inventario."*

**Contradicción detectada:** si el código de almacén se incrusta en el SKU, el mismo producto físico tendría SKUs distintos por almacén, lo cual **viola directamente** el requisito del enunciado *"el SKU deberá permitir identificar de forma inequívoca un producto"*, y rompe la unicidad global del catálogo.

**Dictamen preliminar del AUDITOR:** el SKU permanece **agnóstico al almacén**. `ALM-NTE` es un **localizador de existencias**, no parte de la identidad del producto: se compone en la capa de presentación y en la bitácora como `CAT-PROD-VAR@ALM-NTE`. Esto satisface la trazabilidad y la validación visual **sin** romper la unicidad. Requiere tu ratificación (pregunta 2 al final).

---

## [💻 AGENTE DB-DBA] — Modelo relacional PostgreSQL 15+ (Supabase)

### Decisión de emplazamiento: esquema `wms`, no `public`

Las tablas viven en un esquema dedicado. Esto no es cosmético: en Supabase, PostgREST expone automáticamente `public`. Como la prueba **no requiere auth ni RLS**, publicar el modelo en `public` dejaría un API REST anónimo con acceso directo a inventario, saltándose por completo las reglas de negocio y la idempotencia del backend .NET. Con esquema `wms` + `revoke` sobre `anon`/`authenticated`, **la única puerta al inventario es la API de .NET 8**. Es la mitigación correcta dado el alcance sin RLS.

### Diagrama entidad-relación

```text
  categories ──1:N──► products ──1:N──┐
   (código 3)      (SKU generado)     │
                        │             │
  warehouses ──1:N──────┼─────────────┤
  (ALM-XXX fijo)        │             │
                        ▼             ▼
                   inventory ◄── PK COMPUESTA (product_id, warehouse_id)
                        │  qty_on_hand / qty_reserved / version_ecc
                        │
                        ▼ (TRIGGER AFTER INSERT/UPDATE — append-only)
              inventory_movements  ◄── referencia polimórfica a ORDER / IMPORT / QUICK_ADJUST
                        ▲
                        │
  customers ──1:N──► orders ──1:N──► order_items ──N:1──► products
                   (máquina de estados)   (precio congelado)

  Soporte transversal:  idempotency_keys · sku_format_rules
                        import_batches ──1:N──► import_batch_rows
```

### 1. Catálogos maestros

```sql
create schema if not exists wms;
create extension if not exists pg_trgm;   -- búsqueda difusa por nombre/SKU

create table wms.categories (
  id          bigint generated always as identity primary key,
  code        text        not null,
  name        text        not null,
  description text,
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint categories_code_uk    unique (code),
  constraint categories_code_fmt   check (code ~ '^[A-Z]{3}$'),
  -- ancla para la FK COMPUESTA de products: garantiza el par (id, code)
  constraint categories_id_code_uk unique (id, code)
);
create unique index categories_name_lower_uk on wms.categories (lower(btrim(name)));

create table wms.warehouses (
  id         bigint generated always as identity primary key,
  code       text        not null,
  name       text        not null,
  address    text,
  is_active  boolean     not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint warehouses_code_uk  unique (code),
  -- longitud fija = 7 caracteres, verificado por la propia BD
  constraint warehouses_code_fmt check (code ~ '^ALM-[A-Z0-9]{3}$')
);
```

### 2. Motor de SKU — reglas Regex dinámicas persistidas

El requerimiento pide *"expresiones regulares dinámicas"*. Si el patrón vive hardcodeado en C#, no es dinámico. Vive en la BD, y el servicio de parsing de .NET lo carga en memoria (con caché invalidable), de modo que backend y base **comparten una sola fuente de verdad**:

```sql
create table wms.sku_format_rules (
  id               bigint generated always as identity primary key,
  name             text not null unique,
  separator        text not null default '-'          check (char_length(separator) = 1),
  category_pattern text not null default '[A-Z]{3}',
  product_pattern  text not null default '[A-Z0-9]{4,8}',
  variant_pattern  text not null default '[A-Z0-9]{2,6}',
  full_pattern     text generated always as (
      '^' || category_pattern || separator || product_pattern
           || separator || variant_pattern || '$'
  ) stored,
  is_active  boolean not null default false,
  created_at timestamptz not null default now()
);
-- Invariante: a lo sumo UNA regla activa en todo el sistema
create unique index sku_rules_one_active on wms.sku_format_rules (is_active) where is_active;
```

### 3. Productos — SKU derivado e indestructible

Aquí está la pieza de ingeniería más fina del modelo. El SKU **no se captura ni se puede corromper**:

```sql
create table wms.products (
  id            bigint generated always as identity primary key,
  category_id   bigint not null,
  category_code text   not null,          -- desnormalizado a propósito (ver nota)
  product_code  text   not null,
  variant_code  text   not null default 'STD',
  sku           text   generated always as
                (category_code || '-' || product_code || '-' || variant_code) stored,
  name          text          not null,
  description   text,
  unit_price    numeric(14,2) not null default 0,
  status        text          not null default 'ACTIVE',
  version_ecc   bigint        not null default 1,
  created_at    timestamptz   not null default now(),
  updated_at    timestamptz   not null default now(),

  -- FK COMPUESTA: la BD garantiza que category_code SIEMPRE corresponde a category_id.
  -- Sin triggers de sincronización, sin posibilidad de deriva.
  constraint products_category_fk foreign key (category_id, category_code)
      references wms.categories (id, code) on update cascade on delete restrict,

  constraint products_sku_uk      unique (sku),
  constraint products_natural_uk  unique (category_id, product_code, variant_code),
  constraint products_code_fmt    check (product_code ~ '^[A-Z0-9]{4,8}$'),
  constraint products_variant_fmt check (variant_code  ~ '^[A-Z0-9]{2,6}$'),
  constraint products_status_chk  check (status in ('ACTIVE','INACTIVE','DISCONTINUED')),
  constraint products_price_chk   check (unit_price >= 0)
);

create index products_category_id_idx on wms.products (category_id);
create index products_active_idx      on wms.products (status) where status = 'ACTIVE';
create index products_name_trgm_idx   on wms.products using gin (name gin_trgm_ops);
create index products_sku_trgm_idx    on wms.products using gin (sku  gin_trgm_ops);
```

**Por qué la desnormalización de `category_code` es correcta aquí:** una columna generada en Postgres solo puede referenciar columnas de su propia fila, así que el SKU no puede leer `categories.code` mediante un `JOIN`. La alternativa habitual es un trigger de sincronización — frágil y saltable. La **FK compuesta contra `UNIQUE (id, code)`** logra lo mismo con garantía del motor: es *imposible* insertar un producto cuyo `category_code` no pertenezca a su `category_id`. Política complementaria: `categories.code` es **inmutable si ya existen productos** (trigger de bloqueo), porque un SKU impreso en etiqueta no debe cambiar retroactivamente.

### 4. Inventario — llave primaria compuesta y control de concurrencia

```sql
create table wms.inventory (
  product_id    bigint  not null references wms.products(id)   on delete restrict,
  warehouse_id  bigint  not null references wms.warehouses(id) on delete restrict,
  qty_on_hand   integer not null default 0,
  qty_reserved  integer not null default 0,
  qty_available integer generated always as (qty_on_hand - qty_reserved) stored,
  min_stock     integer not null default 0,
  version_ecc   bigint  not null default 1,     -- token de concurrencia optimista
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint inventory_pk primary key (product_id, warehouse_id),   -- ◄ llave compuesta

  -- LA red de seguridad final: ninguna ruta de código puede dejar stock negativo
  constraint inventory_onhand_chk   check (qty_on_hand  >= 0),
  constraint inventory_reserved_chk check (qty_reserved >= 0),
  constraint inventory_avail_chk    check (qty_reserved <= qty_on_hand),
  constraint inventory_min_chk      check (min_stock    >= 0)
);

create index inventory_by_warehouse_idx on wms.inventory (warehouse_id, product_id);
create index inventory_low_stock_idx    on wms.inventory (warehouse_id, product_id)
       where qty_on_hand <= min_stock;   -- índice parcial: alimenta el KPI de stock bajo
```

La PK compuesta es a la vez el índice principal para `WHERE product_id = ?` y para el bloqueo por fila; el índice invertido `(warehouse_id, product_id)` cubre la vista "inventario del almacén X". El `CHECK (qty_on_hand >= 0)` es deliberadamente la **última** línea de defensa: aunque un desarrollador futuro escriba un `UPDATE` crudo saltándose la API, la base rechaza la sobreventa con `SQLSTATE 23514`.

### 5. Movimientos históricos — bitácora append-only de doble cubeta

```sql
create table wms.inventory_movements (
  id              bigint generated always as identity primary key,
  product_id      bigint  not null,
  warehouse_id    bigint  not null,
  movement_type   text    not null,
  qty_delta       integer not null,            -- delta con signo sobre existencia física
  qty_before      integer not null,
  qty_after       integer not null,
  reserved_delta  integer not null default 0,  -- delta sobre reservado
  reserved_before integer not null default 0,
  reserved_after  integer not null default 0,
  reference_type  text    not null default 'MANUAL',
  reference_id    text,                        -- id de orden / lote de importación
  idempotency_key text,
  reason          text,
  created_by      text    not null default 'system',
  created_at      timestamptz not null default now(),

  constraint mov_inventory_fk foreign key (product_id, warehouse_id)
      references wms.inventory (product_id, warehouse_id) on delete restrict,
  constraint mov_type_chk  check (movement_type in
      ('INBOUND','OUTBOUND','ADJUSTMENT','RESERVATION','RELEASE','SHIPMENT','IMPORT')),
  constraint mov_ref_chk   check (reference_type in
      ('QUICK_ADJUST','ORDER','IMPORT','MANUAL','SEED')),
  -- la aritmética del historial debe cuadrar SIEMPRE
  constraint mov_nonzero_chk  check (qty_delta <> 0 or reserved_delta <> 0),
  constraint mov_math_chk     check (qty_after      = qty_before      + qty_delta),
  constraint mov_res_math_chk check (reserved_after = reserved_before + reserved_delta)
);

create index mov_product_wh_time_idx on wms.inventory_movements (product_id, warehouse_id, created_at desc);
create index mov_time_idx            on wms.inventory_movements (created_at desc);
create index mov_reference_idx       on wms.inventory_movements (reference_type, reference_id);
-- Segunda barrera de idempotencia, a nivel de datos
create unique index mov_idem_uk on wms.inventory_movements (idempotency_key)
       where idempotency_key is not null;
```

**Las dos cubetas (`qty_delta` / `reserved_delta`) resuelven un problema real:** confirmar una orden mueve *reservado* sin mover *físico*, y enviarla mueve ambos. Una bitácora de una sola columna no puede representar eso sin mentir.

### 6. Trigger de automatización (PL/pgSQL) — el invariante que ningún agente puede romper

**Problema que el AUDITOR planteó al DB-DBA:** un trigger sobre `inventory` garantiza que *ningún* cambio de stock quede sin bitácora — pero el trigger no sabe *por qué* cambió (¿orden? ¿ajuste express? ¿importación?). **Solución:** contexto transaccional vía GUCs locales.

```sql
create or replace function wms.fn_log_inventory_movement()
returns trigger language plpgsql as $$
declare v_qty int; v_res int;
begin
  if tg_op = 'INSERT' then
     v_qty := new.qty_on_hand;                    v_res := new.qty_reserved;
  else
     v_qty := new.qty_on_hand  - old.qty_on_hand; v_res := new.qty_reserved - old.qty_reserved;
  end if;

  if v_qty = 0 and v_res = 0 then return null; end if;   -- alta de fila en cero: no es movimiento

  insert into wms.inventory_movements (
      product_id, warehouse_id, movement_type,
      qty_delta, qty_before, qty_after,
      reserved_delta, reserved_before, reserved_after,
      reference_type, reference_id, idempotency_key, reason, created_by)
  values (
      new.product_id, new.warehouse_id,
      coalesce(nullif(current_setting('wms.ctx_movement_type', true), ''),
               case when v_qty > 0 then 'INBOUND' else 'OUTBOUND' end),
      v_qty, coalesce(old.qty_on_hand, 0),  new.qty_on_hand,
      v_res, coalesce(old.qty_reserved, 0), new.qty_reserved,
      coalesce(nullif(current_setting('wms.ctx_reference_type', true), ''), 'MANUAL'),
      nullif(current_setting('wms.ctx_reference_id',   true), ''),
      nullif(current_setting('wms.ctx_idempotency_key',true), ''),
      nullif(current_setting('wms.ctx_reason',         true), ''),
      coalesce(nullif(current_setting('wms.ctx_actor', true), ''), 'system'));
  return null;
end $$;

create trigger trg_inventory_movement
after insert or update of qty_on_hand, qty_reserved on wms.inventory
for each row execute function wms.fn_log_inventory_movement();
```

Se acompaña de `trg_movements_immutable` (`BEFORE UPDATE OR DELETE` → `RAISE EXCEPTION`): **la bitácora es de solo inserción, sin excepciones.**

### 7. Primitiva atómica de ajuste — el corazón del Quick-Adjust

```sql
create or replace function wms.fn_adjust_stock(
  p_product_id bigint, p_warehouse_id bigint, p_delta integer,
  p_movement_type text, p_reference_type text default 'QUICK_ADJUST',
  p_reference_id text default null, p_idempotency_key text default null,
  p_reason text default null, p_expected_version bigint default null,
  p_actor text default 'system'
) returns wms.inventory language plpgsql as $$
declare v_row wms.inventory;
begin
  perform set_config('wms.ctx_movement_type',   p_movement_type, true);
  perform set_config('wms.ctx_reference_type',  p_reference_type, true);
  perform set_config('wms.ctx_reference_id',    coalesce(p_reference_id, ''), true);
  perform set_config('wms.ctx_idempotency_key', coalesce(p_idempotency_key, ''), true);
  perform set_config('wms.ctx_reason',          coalesce(p_reason, ''), true);
  perform set_config('wms.ctx_actor',           p_actor, true);

  insert into wms.inventory (product_id, warehouse_id)
  values (p_product_id, p_warehouse_id)
  on conflict (product_id, warehouse_id) do nothing;   -- alta sin race condition

  -- UPDATE atómico de una sola sentencia: Postgres toma el row lock y re-evalúa
  -- la fila tras esperar. NO existe lost update, aunque lleguen 500 clics simultáneos.
  update wms.inventory
     set qty_on_hand = qty_on_hand + p_delta,
         version_ecc = version_ecc + 1,
         updated_at  = now()
   where product_id = p_product_id and warehouse_id = p_warehouse_id
     and (p_expected_version is null or version_ecc = p_expected_version)
  returning * into v_row;

  if not found then
     raise exception 'WMS_CONCURRENCY_CONFLICT' using errcode = '40001';
  end if;
  return v_row;
end $$;
```

**[🤖 AUDITOR — dictamen sobre concurrencia]** Aquí conviven dos mecanismos que resuelven **problemas distintos**, y confundirlos es el error clásico:

| Mecanismo | Problema que resuelve | Dónde aplica |
|---|---|---|
| `UPDATE ... SET qty = qty + delta` atómico | *Lost update* entre transacciones simultáneas | **Siempre** en Quick-Adjust. El delta es conmutativo: 2 clics de `+1` = `+2`, nunca `+1`. |
| `version_ecc` (opcional en el ajuste) | *Stale read*: la UI decide sobre un valor que ya venció | Formularios de edición (`SET qty = valor_absoluto`) y edición de producto |
| `CHECK (qty_on_hand >= 0)` | Sobreventa por cualquier ruta, incluso SQL manual | Red de seguridad del motor |
| `FOR UPDATE ORDER BY product_id` | *Deadlock* al confirmar órdenes multi-partida | Confirmación/envío de órdenes |

El Quick-Adjust **no debe** exigir `version_ecc` obligatorio: si dos operarios pulsan `+1` a la vez, ambos clics son intención legítima y ambos deben aplicarse. Rechazar el segundo con un 409 sería un bug de producto disfrazado de rigor técnico. `version_ecc` viaja en la respuesta y es opcional en la petición.

### 8. Órdenes — máquina de estados con precios congelados

```sql
create table wms.customers (
  id bigint generated always as identity primary key,
  code text not null unique check (code ~ '^CLI-[A-Z0-9]{4}$'),
  name text not null, email text, phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table wms.orders (
  id            bigint generated always as identity primary key,
  order_number  text   not null unique,          -- ORD-20260821-000042
  customer_id   bigint not null references wms.customers(id)  on delete restrict,
  warehouse_id  bigint not null references wms.warehouses(id) on delete restrict,
  status        text   not null default 'DRAFT',
  total_amount  numeric(16,2) not null default 0,
  notes         text,
  version_ecc   bigint not null default 1,
  confirmed_at timestamptz, shipped_at timestamptz,
  cancelled_at timestamptz, cancel_reason text,
  created_by   text not null default 'system',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint orders_status_chk check (status in ('DRAFT','CONFIRMED','SHIPPED','CANCELLED')),
  constraint orders_total_chk  check (total_amount >= 0),
  constraint orders_cancel_chk check ((status = 'CANCELLED') = (cancelled_at is not null))
);
create index orders_status_time_idx on wms.orders (status, created_at desc);
create index orders_customer_idx    on wms.orders (customer_id, created_at desc);
create index orders_warehouse_idx   on wms.orders (warehouse_id);

create table wms.order_items (
  id            bigint generated always as identity primary key,
  order_id      bigint not null references wms.orders(id)   on delete cascade,
  product_id    bigint not null references wms.products(id) on delete restrict,
  sku_snapshot  text   not null,          -- historia inmutable
  name_snapshot text   not null,
  quantity      integer       not null,
  unit_price    numeric(14,2) not null,
  line_total    numeric(16,2) generated always as (quantity * unit_price) stored,
  constraint order_items_uk        unique (order_id, product_id),
  constraint order_items_qty_chk   check (quantity > 0),
  constraint order_items_price_chk check (unit_price >= 0)
);
create index order_items_product_idx on wms.order_items (product_id);
```

Máquina de estados validada por `trg_order_status_transition` (`BEFORE UPDATE`):

```text
DRAFT ──confirmar──► CONFIRMED ──enviar──► SHIPPED   (terminal)
  │                      │
  └──cancelar────────────┴──cancelar──► CANCELLED    (terminal)

SHIPPED ─✗─► cualquier estado    (una orden enviada no se cancela: se devuelve)
```

### 9. Idempotencia e importación

```sql
create table wms.idempotency_keys (
  key           text primary key,
  endpoint      text not null,
  request_hash  text not null,               -- SHA-256 del cuerpo canonicalizado
  status        text not null default 'IN_PROGRESS',
  response_code integer,
  response_body jsonb,
  created_at    timestamptz not null default now(),
  completed_at  timestamptz,
  expires_at    timestamptz not null default now() + interval '48 hours',
  constraint idem_status_chk check (status in ('IN_PROGRESS','COMPLETED','FAILED'))
);
create index idem_expires_idx on wms.idempotency_keys (expires_at);   -- purga vía pg_cron

create table wms.import_batches (
  id bigint generated always as identity primary key,
  file_name text not null,
  kind      text not null check (kind in ('PRODUCTS','INVENTORY','COMBINED')),
  mode      text not null default 'CREATE_ONLY' check (mode in ('CREATE_ONLY','UPSERT')),
  status    text not null default 'PROCESSING'
            check (status in ('PROCESSING','COMPLETED','COMPLETED_WITH_ERRORS','FAILED')),
  total_rows integer not null default 0,
  ok_rows    integer not null default 0,
  failed_rows integer not null default 0,
  idempotency_key text,
  created_by text not null default 'system',
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

create table wms.import_batch_rows (
  id bigint generated always as identity primary key,
  batch_id   bigint not null references wms.import_batches(id) on delete cascade,
  row_number integer not null,
  raw_payload jsonb  not null,               -- el renglón tal cual llegó, para diagnóstico
  status     text not null check (status in ('OK','ERROR','SKIPPED')),
  error_code text, error_message text,
  product_id bigint references wms.products(id) on delete set null,
  constraint import_row_uk unique (batch_id, row_number)
);
create index import_rows_status_idx on wms.import_batch_rows (batch_id, status);
```

**El flujo idempotente completo** (`INSERT ... ON CONFLICT DO NOTHING` sobre `idempotency_keys` — sin race, sin `SELECT` previo):

```text
POST /inventory/adjust  +  X-Idempotency-Key: 7f3a…
        │
        ├─ INSERT clave → filas=1 → procesa, guarda respuesta, status=COMPLETED → 200
        ├─ INSERT clave → filas=0 + COMPLETED   + mismo hash → devuelve respuesta original → 200
        ├─ INSERT clave → filas=0 + COMPLETED   + hash distinto → 409 Conflict
        └─ INSERT clave → filas=0 + IN_PROGRESS → 409 (Polly reintenta con backoff exponencial)
```

### 10. Vistas de dashboard y datos semilla

Vistas `v_inventory_board` (inventario × almacén con SKU y localizador compuesto), `v_low_stock`, `v_dashboard_kpis` y `v_orders_by_status_daily` — para que Recharts consuma agregados ya calculados en Postgres en lugar de traer filas crudas al navegador. Semilla: 5 categorías, 3 almacenes, ~40 productos, inventario poblado y 8 órdenes en distintos estados.

---

## [🧪 AGENTE QA / TESTING] — Matriz preliminar (adelanto, sin código aún)

| # | Escenario | Resultado esperado | Nivel |
|---|---|---|---|
| C1 | 50 tareas paralelas `+1` sobre la misma fila de inventario | `qty_on_hand = inicial + 50`; exactamente 50 movimientos | Integración (Testcontainers) |
| C2 | Doble clic con **la misma** `X-Idempotency-Key` | Un solo movimiento; segunda respuesta idéntica a la primera | Integración |
| C3 | Salida concurrente que excede el stock disponible | Una tiene éxito, la otra falla con 422; `qty_on_hand` nunca < 0 | Integración |
| C4 | Dos órdenes confirmadas a la vez sobre el último producto | Una CONFIRMED, otra rechazada; sin deadlock | Integración |
| C5 | SKU malformado en importación masiva | Fila marcada `ERROR`, resto del lote procesado | Unitaria + Integración |
| C6 | Cancelar orden `SHIPPED` | 409, inventario intacto | Unitaria |
| C7 | Ciclo E2E: producto → inventario → orden → confirmar → enviar → movimientos → dashboard | Cadena consistente extremo a extremo | Playwright |

---

## [🤖 AGENTE ARCHITECT] — Veredicto y bloqueo

**Estado: ⏸️ APROBACIÓN CONDICIONADA.** El modelo es internamente consistente y satisface los 12 requisitos del enunciado más los 3 requerimientos añadidos. **No autorizo el paso a Fase 2** hasta cerrar cuatro decisiones que alteran el esquema físico — resolverlas después costaría una migración destructiva.

Te presento las cuatro con mi recomendación fundamentada:

---

‹ 1 operaciones de herramienta: AskUserQuestion×1 ›

### [CLAUDE] · 2026-08-21 22:52:57 UTC

*(preguntas planteadas al usuario para desbloquear el diseño)*

**El tercer segmento del SKU `[CATEGORÍA]-[PRODUCTO]-[VARIANTE/LOTE]` es ambiguo: ¿es un atributo del producto o una dimensión del inventario?**
  - Variante = parte del producto (Recomendado) — El SKU identifica una fila de products (ej. TSH-CAM001-RED, TSH-CAM001-BLU son productos distintos). Stock por (producto, almacén). Cumple 'SKU identifica inequívocamente un producto' del enunciado y mantiene la PK compuesta de 2 columnas.
  - Lote = dimensión del inventario — El stock pasa a ser por (producto, almacén, lote): PK de 3 columnas, y se abren caducidad y estrategia FEFO. Más realista para un WMS de verdad, pero ~40% más de superficie de código y de pruebas. El enunciado nunca menciona lotes ni caducidad.
  - Variante ahora, lote preparado — Se modela como variante, pero se deja la columna lot_code nullable en inventory con default '*' dentro de la PK, para habilitar lotes después sin migración destructiva. Complejidad intermedia.

**¿Ratificas el dictamen del AUDITOR sobre el código de almacén (`ALM-NTE`) frente al SKU?**
  - Localizador, fuera del SKU (Recomendado) — El SKU permanece global y único por producto. El código de almacén se compone en la UI y la bitácora como localizador 'TSH-CAM001-RED@ALM-NTE'. Es la única lectura que NO contradice el requisito 'el SKU identifica inequívocamente un producto' del enunciado original.
  - Incrustado en el SKU — El SKU se vuelve ALM-NTE-TSH-CAM001-RED. El mismo producto físico tendría SKUs distintos por almacén: se rompe la unicidad global del catálogo y las órdenes multi-almacén se vuelven inviables. Lo desaconsejo formalmente.
  - Columna derivada persistida — Se agrega inventory.locator_code como columna GENERATED STORED que concatena SKU y código de almacén, indexada y buscable. El SKU sigue limpio, pero el localizador es consultable por SQL directamente. Cuesta una columna extra por fila de inventario.

**El enunciado exige creación, confirmación, envío y cancelación de órdenes, pero no define cuándo se descuenta el inventario. ¿Qué política adoptamos?**
  - Reservar al confirmar, descontar al enviar (Recomendado) — CONFIRMED incrementa qty_reserved; SHIPPED baja qty_on_hand y libera la reserva; CANCELLED libera la reserva. Es el comportamiento correcto de un WMS, hace significativo qty_available y produce escenarios de concurrencia mucho más ricos para las pruebas. Requiere las dos cubetas ya modeladas.
  - Descontar al confirmar — CONFIRMED baja qty_on_hand directamente; CANCELLED lo repone. Se elimina qty_reserved y el modelo se simplifica, pero se pierde la distinción entre existencia física y disponible, y cancelar tras confirmar reintroduce stock que quizá ya se surtió.
  - Descontar al enviar únicamente — CONFIRMED solo valida disponibilidad sin tocar nada; SHIPPED descuenta. El más simple de todos, pero permite sobreventa entre confirmación y envío: dos órdenes pueden confirmarse contra el mismo stock. Contradice 'no permitir operaciones que produzcan inconsistencias'.

**¿Dónde debe residir la mutación atómica de inventario: en funciones PL/pgSQL o exclusivamente en los handlers de .NET?**
  - Híbrido: primitiva en BD, orquestación en .NET (Recomendado) — MediatR/CQRS gobierna validación, parsing de SKU, idempotencia y mapeo de errores; la BD expone fn_adjust_stock / fn_confirm_order como única primitiva de mutación. Ninguna ruta de código puede violar el invariante, y se evitan round-trips en la sección crítica. La BD es la última autoridad.
  - Todo en .NET con EF Core — Handlers puros con transacciones explícitas, SELECT FOR UPDATE y RowVersion de EF Core. Clean Architecture más ortodoxa y más fácil de probar con NSubstitute, pero cada operación cuesta varios round-trips y la lógica es saltable por SQL directo.
  - Todo en PL/pgSQL, .NET como pasarela — Máxima atomicidad y mínima latencia, pero contradice el requisito de arquitectura empresarial .NET con CQRS/MediatR y hace la lógica de negocio difícil de probar unitariamente. No lo recomiendo para esta prueba.

---

### [USUARIO] · 2026-08-21 23:07:57 UTC

*(respuesta a las preguntas planteadas por Claude)*

The user answered: "El tercer segmento del SKU `[CATEGORÍA]-[PRODUCTO]-[VARIANTE/LOTE]` es ambiguo: ¿es un atributo del producto o una dimensión del inventario?"="Que el SKU sea [Categoria]-[Consecutivo Producto] EJ ELEC-0001, ELEC-0002. Evalua si es necesario incluir algo como tipo, o mas informacion en esta", "¿Ratificas el dictamen del AUDITOR sobre el código de almacén (`ALM-NTE`) frente al SKU?"="Localizador, fuera del SKU (Recomendado)", "El enunciado exige creación, confirmación, envío y cancelación de órdenes, pero no define cuándo se descuenta el inventario. ¿Qué política adoptamos?"="Reservar al confirmar, descontar al enviar (Recomendado)", "¿Dónde debe residir la mutación atómica de inventario: en funciones PL/pgSQL o exclusivamente en los handlers de .NET?"="Híbrido: primitiva en BD, orquestación en .NET (Recomendado)". Read the answers carefully — they may request clarification, changes, or that you not proceed — and follow what they actually say.

---

### [CLAUDE] · 2026-08-21 23:10:06 UTC

## [🤖 AGENTE ARCHITECT / AUDITOR] — Decisiones ratificadas

| Decisión | Resolución | Impacto en el esquema |
|---|---|---|
| Formato de SKU | **`[CATEGORÍA]-[CONSECUTIVO]`** → `ELEC-0001` | 🔴 **Rediseño de `products`** (abajo) |
| Código de almacén | Localizador externo al SKU | ✅ Sin cambios — dictamen ratificado |
| Ciclo de orden | Reservar al confirmar, descontar al enviar | ✅ Sin cambios — doble cubeta ya modelada |
| Mutación atómica | Híbrido: primitiva PL/pgSQL + orquestación .NET | ✅ Sin cambios — `fn_adjust_stock` confirmada |

Tu decisión sobre el SKU **invalida una parte de mi propuesta anterior** y obliga a rediseñarla. Lo explico sin rodeos porque el motivo importa.

---

## Evaluación solicitada: ¿debe el SKU llevar "tipo" o más información?

### Dictamen: **NO. Dos segmentos y nada más.** `ELEC-0001` es la respuesta correcta.

Mi recomendación previa (tres segmentos con variante) era inferior a la tuya. Fundamento:

**1. Todo atributo mutable dentro de un identificador inmutable se convierte en una mentira.**
Este es el error de modelado más caro y más frecuente en sistemas WMS: los *significant part numbers*. Si el SKU codifica el tipo (`ELEC-ACC-0001`) y mañana el producto se reclasifica de "accesorio" a "componente", solo hay tres salidas y las tres son malas: el SKU miente, se reemite el SKU y se rompe el historial de órdenes, o se prohíbe la reclasificación. GS1, SAP y Oracle WMS convergieron hace décadas en lo mismo: **el identificador es opaco; los atributos son columnas.**

**2. El consecutivo por sí solo ya garantiza unicidad.** El prefijo `ELEC` es *afordancia humana*, no identidad: sirve para que un operario en piso reconozca de qué familia habla sin consultar el sistema. Añadir un tercer segmento no aporta unicidad, solo superficie de error de captura.

**3. Un atributo en columna es filtrable, ordenable, indexable y — sobre todo — corregible.** El SKU no es ninguna de las cuatro cosas. Cualquier cosa que quieras codificar (tipo, marca, temporada, variante) rinde estrictamente más como columna indexada que como caracteres dentro del SKU.

**4. Longitud fija = parsing trivial.** Con categoría de 4 caracteres y consecutivo de 4 dígitos, **todo SKU mide exactamente 9 caracteres**. Esa invariante simplifica el regex, el ancho de la columna en la tabla del frontend, la etiqueta impresa y la lectura por escáner. Un tercer segmento de longitud variable la destruye.

### Lo único que evalué y sí podría justificar un tercer segmento

Un marcador de **tipo de artículo** (`P`=producto simple, `K`=kit, `S`=servicio) es defendible **solo cuando el tipo cambia las reglas de manejo físico** — un kit no se almacena, se explota en componentes al surtir. El enunciado no menciona kits, servicios ni listas de materiales. **YAGNI: rechazado.** Si aparecieran, la vía correcta sería `products.item_type text` como columna con `CHECK`, jamás un segmento del SKU.

### Consecuencia que sí debes conocer y aceptar explícitamente

Como el SKU se **acuña** una sola vez y se congela:

- Un producto creado en `ELEC` que después se reclasifique a `HOGA` **conservará el SKU `ELEC-0001` para siempre**. Su categoría vigente vivirá en `category_id` (mutable, filtrable), y el prefijo será un registro histórico de su origen.
- **Esto es correcto, no un defecto**: la etiqueta ya está impresa en la caja y el SKU ya está en órdenes cerradas. Reescribirlo corrompería el historial.
- **Techo:** 9 999 productos por categoría. Suficiente con margen amplio; la ampliación a 5 dígitos es una migración no destructiva del `sku_format_rules` + backfill.

---

## [💻 AGENTE DB-DBA] — Δ del modelo: acuñación de SKU

### Por qué cambia el mecanismo, no solo el formato

Mi diseño anterior usaba una **columna derivada de la FK compuesta**: el SKU se recalculaba desde la categoría vigente. Eso era correcto para un SKU *derivado*, pero tu formato lo convierte en un SKU *acuñado* — un consecutivo se asigna una vez y no se recalcula jamás. Mantener la FK compuesta con `ON UPDATE CASCADE` ahora sería un **bug latente**: reclasificar un producto le reescribiría el SKU en silencio.

**Solución:** el SKU sigue siendo `GENERATED STORED` (imposible de desincronizar), pero deriva de **dos columnas congeladas de acuñación** en lugar de la FK viva.

```sql
-- categories: se añade el contador de acuñación por categoría
alter table wms.categories
  add column seq_counter integer not null default 0
      check (seq_counter >= 0 and seq_counter <= 9999);

-- El código de categoría pasa a longitud fija de 4 (ELEC, HOGA, ALIM, ROPA…)
alter table wms.categories
  drop constraint categories_code_fmt,
  add  constraint categories_code_fmt check (code ~ '^[A-Z]{4}$');
-- Ya NO se requiere categories_id_code_uk: la FK compuesta queda descartada.
```

```sql
create table wms.products (
  id          bigint generated always as identity primary key,

  -- categoría VIGENTE: mutable, filtrable, es la verdad operativa
  category_id bigint  not null references wms.categories(id) on delete restrict,

  -- columnas de ACUÑACIÓN: se fijan al alta y son inmutables por trigger
  sku_prefix  text    not null,        -- categories.code al momento del alta
  product_seq integer not null,        -- consecutivo dentro de ese prefijo

  -- identidad derivada: ancho fijo de 9 caracteres, ej. ELEC-0001
  sku         text generated always as
              (sku_prefix || '-' || lpad(product_seq::text, 4, '0')) stored,

  name        text          not null,
  description text,
  unit_price  numeric(14,2) not null default 0,
  status      text          not null default 'ACTIVE',
  version_ecc bigint        not null default 1,
  created_at  timestamptz   not null default now(),
  updated_at  timestamptz   not null default now(),

  constraint products_sku_uk     unique (sku),
  constraint products_mint_uk    unique (sku_prefix, product_seq),   -- no hay colisión posible
  constraint products_prefix_fmt check (sku_prefix ~ '^[A-Z]{4}$'),
  constraint products_seq_chk    check (product_seq between 1 and 9999),
  constraint products_status_chk check (status in ('ACTIVE','INACTIVE','DISCONTINUED')),
  constraint products_price_chk  check (unit_price >= 0),
  constraint products_name_chk   check (char_length(btrim(name)) between 2 and 200)
);

create index products_category_id_idx on wms.products (category_id);
create index products_active_idx      on wms.products (status) where status = 'ACTIVE';
create index products_sku_pattern_idx on wms.products (sku text_pattern_ops);  -- LIKE 'ELEC-%'
create index products_name_trgm_idx   on wms.products using gin (name gin_trgm_ops);
```

### Acuñación libre de condiciones de carrera

El punto crítico: **dos altas simultáneas en la misma categoría no pueden recibir el mismo consecutivo.** `max(seq)+1` es una race condition clásica; una secuencia por categoría exigiría DDL dinámico. La solución es el contador con `UPDATE ... RETURNING`, que toma el row lock de la categoría de forma atómica:

```sql
create or replace function wms.fn_mint_product_sku()
returns trigger language plpgsql as $$
begin
  if new.sku_prefix is null then
     select code into strict new.sku_prefix
       from wms.categories where id = new.category_id;
  end if;

  if new.product_seq is null then
     -- UPDATE atómico: toma el row lock de la categoría y devuelve el folio.
     -- Dos INSERT concurrentes se serializan aquí; jamás obtienen el mismo número.
     update wms.categories
        set seq_counter = seq_counter + 1
      where code = new.sku_prefix
      returning seq_counter into strict new.product_seq;
  end if;
  return new;
end $$;

create trigger trg_products_mint_sku
before insert on wms.products
for each row execute function wms.fn_mint_product_sku();

-- El SKU acuñado es intocable: bloquea cualquier intento de reescritura
create or replace function wms.fn_products_sku_immutable()
returns trigger language plpgsql as $$
begin
  if new.sku_prefix is distinct from old.sku_prefix
     or new.product_seq is distinct from old.product_seq then
     raise exception 'WMS_SKU_IMMUTABLE: el SKU % no puede reasignarse', old.sku
       using errcode = '23514';
  end if;
  return new;
end $$;

create trigger trg_products_sku_immutable
before update on wms.products
for each row execute function wms.fn_products_sku_immutable();
```

**Nota de operación (documentada como supuesto):** un `ROLLBACK` posterior a la acuñación consume el folio y deja un hueco en la serie (`ELEC-0003` puede no existir nunca). Es el mismo comportamiento que una `SEQUENCE` de Postgres y es intencional — garantizar una serie sin huecos exigiría serializar globalmente las altas, precio inaceptable durante una importación masiva. El consecutivo es un identificador, no un folio fiscal.

### Reglas Regex dinámicas — actualizadas a dos segmentos

```sql
create table wms.sku_format_rules (
  id             bigint generated always as identity primary key,
  name           text    not null unique,
  separator      text    not null default '-'      check (char_length(separator) = 1),
  prefix_pattern text    not null default '[A-Z]{4}',
  seq_length     integer not null default 4        check (seq_length between 3 and 8),
  full_pattern   text generated always as (
      '^' || prefix_pattern || separator || '[0-9]{' || seq_length::text || '}$'
  ) stored,
  is_active      boolean not null default false,
  created_at     timestamptz not null default now()
);
create unique index sku_rules_one_active on wms.sku_format_rules (is_active) where is_active;

insert into wms.sku_format_rules (name, is_active) values ('DEFAULT_V1', true);
-- full_pattern resultante: ^[A-Z]{4}-[0-9]{4}$
```

El servicio de parsing de .NET 8 carga `full_pattern` desde esta tabla (con caché invalidable), de modo que **backend y base comparten una sola fuente de verdad** para la validación — requisito de "Regex dinámicas" satisfecho de forma real, no simulada. `SkuParser.Parse("ELEC-0042")` devuelve `{ Prefix = "ELEC", Sequence = 42 }` y se usa como puerta de entrada de la importación masiva antes de tocar la base.

### Localizador de inventario (decisión ratificada)

```sql
-- Vista: el SKU permanece global; el almacén compone el localizador en lectura
create view wms.v_inventory_board as
select i.product_id, i.warehouse_id,
       p.sku, p.name as product_name, c.code as category_code, c.name as category_name,
       w.code as warehouse_code,
       p.sku || '@' || w.code as locator_code,        -- ELEC-0001@ALM-NTE
       i.qty_on_hand, i.qty_reserved, i.qty_available, i.min_stock,
       (i.qty_on_hand <= i.min_stock) as is_low_stock,
       i.version_ecc, i.updated_at, p.unit_price, p.status as product_status
  from wms.inventory  i
  join wms.products   p on p.id = i.product_id
  join wms.categories c on c.id = p.category_id
  join wms.warehouses w on w.id = i.warehouse_id;
```

---

## [🤖 AGENTE ARCHITECT] — Estado del modelo

**✅ Modelo relacional cerrado.** 12 tablas, 3 vistas, 8 triggers, 4 funciones atómicas, 0 ambigüedades abiertas. Las cuatro decisiones de arquitectura están ratificadas y sus consecuencias documentadas.

**Siguiente paso del protocolo (Fase 1 → cierre):** consolidar todo lo acordado — enunciado, 12 ambigüedades con su resolución, DDL completo, máquina de estados, estrategia de concurrencia/idempotencia, contratos de endpoints y matriz de pruebas QA — en un documento de especificación versionado:

📄 `docs/superpowers/specs/2026-08-21-mini-wms-ordenes-design.md`

Ese archivo será el contrato que gobierne a los agentes BACKEND, FRONTEND y QA, y es además evidencia directa de supervisión para el `AI-USAGE.md` que exige la prueba.

**Los agentes BACKEND y FRONTEND siguen bloqueados.** No se escribirá código de aplicación hasta que revises y apruebes el spec.

¿Procedo a escribir el documento de especificación con todo lo acordado, o quieres ajustar algo del modelo antes?

---
