-- =====================================================================
--  Mini WMS + Órdenes  ·  0001 · Esquema relacional
--  PostgreSQL 15+ / Supabase
-- ---------------------------------------------------------------------
--  CONVENCIÓN DE NOMBRES
--    cat_  catálogo / información de referencia relativamente estática
--    tbl_  data operativa o transaccional
--    rel_  relación entre entidades con ciclo de vida dependiente
--    Identificadores: minúsculas, snake_case, español.
--    Sufijo _en  => timestamptz          Prefijo es_ => boolean
--    pk_ uq_ fk_ ck_ ix_ ux_ trg_ fn_ vw_ seq_
--    Excepciones léxicas aceptadas (términos de dominio no traducibles):
--      sku, hash, jsonb.
-- ---------------------------------------------------------------------
--  DISCRIMINADOR DE PREFIJO
--    rel_ : la fila NO tiene ciclo de vida propio. Existe solo como
--           componente de una entidad padre y muere con ella (CASCADE).
--    tbl_ : la fila sobrevive a las transacciones que la tocan, tiene
--           estado propio y otras entidades se le restringen (RESTRICT).
--    cat_ : dato de referencia. Se lee mucho, se escribe poco, su borrado
--           está restringido por definición.
-- ---------------------------------------------------------------------
--  SQLSTATE de negocio (clase WM, propia del sistema)
--    WM001 Transición de orden inválida     WM008 Conflicto de concurrencia
--    WM002 Existencia insuficiente          WM009 Formato de SKU inválido
--    WM003 SKU inmutable                    WM010 Total derivado
--    WM004 SKU duplicado                    WM011 Orden sin partidas
--    WM005 Sin inventario en el almacén     WM012 Argumento inválido
--    WM006 Bitácora inmutable               WM013 Operación duplicada en curso
--    WM007 Orden no editable                WM014 Usuario inactivo
--                                           WM015 Operación repetida con carga distinta
--                                           WM016 Operación de otro operador
-- =====================================================================

create schema if not exists wms;
create extension if not exists pg_trgm;

-- =====================================================================
--  ACTORES
-- =====================================================================
-- La prueba no lleva autenticación, pero la trazabilidad exige saber QUIÉN
-- ejecutó cada movimiento. cat_usuarios es un registro de operadores sin
-- credenciales: el frontend selecciona el operador activo y la API lo
-- propaga a toda la bitácora. Es el mínimo que permite auditar sin
-- construir un sistema de identidad fuera de alcance.
create sequence wms.seq_cat_usuarios as integer minvalue 1 maxvalue 9999;

create table wms.cat_usuarios (
  id                         bigint generated always as identity,
  consecutivo                integer not null default nextval('wms.seq_cat_usuarios'),
  codigo                     text generated always as ('USR-' || lpad(consecutivo::text, 4, '0')) stored,
  nombre                     text    not null,
  correo                     text,
  rol                        text    not null default 'OPERADOR',
  es_activo                  boolean not null default true,
  desactivado_en             timestamptz,
  desactivado_por_usuario_id bigint,
  creado_en                  timestamptz not null default now(),
  actualizado_en             timestamptz not null default now(),
  constraint pk_cat_usuarios              primary key (id),
  constraint fk_cat_usuarios__desactivado_por foreign key (desactivado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint uq_cat_usuarios__codigo      unique (codigo),
  constraint uq_cat_usuarios__consecutivo unique (consecutivo),
  constraint ck_cat_usuarios__rol         check (rol in ('OPERADOR','SUPERVISOR','SISTEMA')),
  constraint ck_cat_usuarios__nombre_longitud check (char_length(btrim(nombre)) between 2 and 200),
  -- Soft-delete auditado: desactivar exige registrar cuándo.
  constraint ck_cat_usuarios__sello_baja  check (
             es_activo or (desactivado_en is not null and desactivado_por_usuario_id is not null))
);

comment on table wms.cat_usuarios is
  'Registro de operadores. Sin credenciales: el alcance excluye autenticación. Nunca se borra (RESTRICT en toda la bitácora): la baja es lógica y auditada.';

-- =====================================================================
--  CATÁLOGOS
-- =====================================================================

-- Catálogo de categorías. Además de clasificar, custodia el contador de
-- acuñación que asigna el consecutivo del SKU (ver fn_acunar_sku_producto).
create table wms.cat_categorias (
  id               bigint generated always as identity,
  codigo           text        not null,
  nombre           text        not null,
  descripcion      text,
  consecutivo_sku  integer     not null default 0,
  es_activo        boolean     not null default true,
  desactivado_en             timestamptz,
  desactivado_por_usuario_id bigint,
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now(),
  constraint pk_cat_categorias                    primary key (id),
  constraint fk_cat_categorias__cat_usuarios      foreign key (desactivado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint uq_cat_categorias__codigo            unique (codigo),
  constraint ck_cat_categorias__codigo_formato    check (codigo ~ '^[A-Z]{4}$'),
  constraint ck_cat_categorias__nombre_longitud   check (char_length(btrim(nombre)) between 2 and 120),
  constraint ck_cat_categorias__consecutivo_rango check (consecutivo_sku between 0 and 9999),
  constraint ck_cat_categorias__sello_baja        check (
             es_activo or (desactivado_en is not null and desactivado_por_usuario_id is not null))
);
create unique index ux_cat_categorias__nombre_normalizado
  on wms.cat_categorias (lower(btrim(nombre)));

comment on table  wms.cat_categorias is
  'Catálogo de categorías de producto. El código de 4 letras es el prefijo del SKU.';
comment on column wms.cat_categorias.consecutivo_sku is
  'Último consecutivo acuñado para esta categoría. Se autorrepara contra cat_productos.';

-- Catálogo de almacenes. El código es de longitud fija (7) e inmutable de
-- facto: participa en el localizador SKU@CÓDIGO_ALMACÉN de toda la bitácora.
create table wms.cat_almacenes (
  id             bigint generated always as identity,
  codigo         text        not null,
  nombre         text        not null,
  direccion      text,
  es_activo      boolean     not null default true,
  desactivado_en             timestamptz,
  desactivado_por_usuario_id bigint,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  constraint pk_cat_almacenes                  primary key (id),
  constraint fk_cat_almacenes__cat_usuarios    foreign key (desactivado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint uq_cat_almacenes__codigo          unique (codigo),
  constraint ck_cat_almacenes__codigo_formato  check (codigo ~ '^ALM-[A-Z0-9]{3}$'),
  constraint ck_cat_almacenes__nombre_longitud check (char_length(btrim(nombre)) between 2 and 120),
  constraint ck_cat_almacenes__sello_baja      check (
             es_activo or (desactivado_en is not null and desactivado_por_usuario_id is not null))
);

comment on table wms.cat_almacenes is
  'Catálogo de almacenes. El código NO forma parte del SKU: es un localizador.';

-- Reglas Regex del SKU. Vive en base de datos para que el servicio de
-- parsing de .NET y el motor compartan una sola fuente de verdad.
create table wms.cat_reglas_sku (
  id                   bigint generated always as identity,
  nombre               text    not null,
  separador            text    not null default '-',
  patron_prefijo       text    not null default '[A-Z]{4}',
  longitud_consecutivo integer not null default 4,
  patron_completo      text generated always as (
      '^' || patron_prefijo || separador || '[0-9]{' || longitud_consecutivo::text || '}$'
  ) stored,
  es_activo  boolean     not null default false,
  creado_en  timestamptz not null default now(),
  constraint pk_cat_reglas_sku                 primary key (id),
  constraint uq_cat_reglas_sku__nombre         unique (nombre),
  constraint ck_cat_reglas_sku__separador      check (separador ~ '^[-_/]$'),
  constraint ck_cat_reglas_sku__longitud_rango check (longitud_consecutivo between 3 and 8)
);
-- A lo sumo una regla activa en todo el sistema.
create unique index ux_cat_reglas_sku__unica_activa
  on wms.cat_reglas_sku (es_activo) where es_activo;

create sequence wms.seq_cat_clientes as integer minvalue 1 maxvalue 9999;

-- Catálogo de clientes. El código es opaco y consecutivo: no incorpora el
-- nombre comercial ni ningún dato que pueda cambiar.
create table wms.cat_clientes (
  id             bigint generated always as identity,
  consecutivo    integer not null default nextval('wms.seq_cat_clientes'),
  codigo         text generated always as ('CLI-' || lpad(consecutivo::text, 4, '0')) stored,
  nombre         text    not null,
  correo         text,
  telefono       text,
  es_activo      boolean not null default true,
  desactivado_en             timestamptz,
  desactivado_por_usuario_id bigint,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  constraint pk_cat_clientes                  primary key (id),
  constraint fk_cat_clientes__cat_usuarios    foreign key (desactivado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint uq_cat_clientes__codigo          unique (codigo),
  constraint uq_cat_clientes__consecutivo     unique (consecutivo),
  constraint ck_cat_clientes__nombre_longitud check (char_length(btrim(nombre)) between 2 and 200),
  constraint ck_cat_clientes__correo_formato  check (correo is null or correo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint ck_cat_clientes__sello_baja      check (
             es_activo or (desactivado_en is not null and desactivado_por_usuario_id is not null))
);

-- Catálogo de productos.
--   categoria_id  : categoría VIGENTE. Mutable, filtrable, verdad operativa.
--   sku_prefijo   : código de categoría AL MOMENTO DEL ALTA. Congelado.
--   sku_consecutivo: folio dentro de ese prefijo. Congelado.
--   sku           : derivado de las dos columnas congeladas. Imposible de
--                   desincronizar. Ancho fijo de 9 caracteres (ELEC-0001).
-- La recategorización posterior está permitida y NO reescribe el SKU: una
-- etiqueta impresa y una orden cerrada no pueden cambiar retroactivamente.
create table wms.cat_productos (
  id                   bigint generated always as identity,
  categoria_id         bigint  not null,
  sku_prefijo          text    not null,
  sku_consecutivo      integer not null,
  sku                  text generated always as
                       (sku_prefijo || '-' || lpad(sku_consecutivo::text, 4, '0')) stored,
  nombre               text          not null,
  descripcion          text,
  precio_unitario      numeric(14,2) not null default 0,
  -- estatus con 3 valores en vez de es_activo booleano: excepción explícita
  -- al vocabulario de vigencia de los otros catálogos, por cardinalidad.
  estatus              text          not null default 'ACTIVO',
  version_concurrencia bigint        not null default 1,
  desactivado_en             timestamptz,
  desactivado_por_usuario_id bigint,
  creado_en            timestamptz   not null default now(),
  actualizado_en       timestamptz   not null default now(),
  constraint pk_cat_productos primary key (id),
  constraint fk_cat_productos__cat_usuarios foreign key (desactivado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint ck_cat_productos__sello_baja check (
             estatus = 'ACTIVO' or (desactivado_en is not null and desactivado_por_usuario_id is not null)),
  constraint fk_cat_productos__cat_categorias foreign key (categoria_id)
             references wms.cat_categorias (id) on delete restrict on update cascade,
  -- El prefijo congelado debe corresponder a ALGUNA categoría existente,
  -- no necesariamente a la vigente. Permite recategorizar sin romper el SKU
  -- y a la vez impide borrar una categoría cuyo código está acuñado.
  constraint fk_cat_productos__prefijo_categoria foreign key (sku_prefijo)
             references wms.cat_categorias (codigo) on delete restrict on update restrict,
  constraint uq_cat_productos__sku                unique (sku),
  constraint uq_cat_productos__acunacion          unique (sku_prefijo, sku_consecutivo),
  constraint ck_cat_productos__prefijo_formato    check (sku_prefijo ~ '^[A-Z]{4}$'),
  constraint ck_cat_productos__consecutivo_rango  check (sku_consecutivo between 1 and 9999),
  constraint ck_cat_productos__estatus            check (estatus in ('ACTIVO','INACTIVO','DESCONTINUADO')),
  constraint ck_cat_productos__precio_no_negativo check (precio_unitario >= 0),
  constraint ck_cat_productos__nombre_longitud    check (char_length(btrim(nombre)) between 2 and 200)
);
create index ix_cat_productos__categoria    on wms.cat_productos (categoria_id);
create index ix_cat_productos__activos      on wms.cat_productos (estatus) where estatus = 'ACTIVO';
create index ix_cat_productos__sku_prefijo  on wms.cat_productos (sku text_pattern_ops);
create index ix_cat_productos__nombre_trgm  on wms.cat_productos using gin (nombre gin_trgm_ops);

-- =====================================================================
--  OPERACIÓN / TRANSACCIONAL
-- =====================================================================

-- Existencias por producto y almacén.
-- CLASIFICADA COMO tbl_ Y NO COMO rel_ (caso señalado en la especificación):
-- su forma es N:M pero su propósito no es vincular, sino custodiar el estado
-- más volátil del sistema. No se cascadea, sobrevive a toda transacción y es
-- tabla REFERENCIADA por la bitácora.
create table wms.tbl_inventario (
  producto_id          bigint  not null,
  almacen_id           bigint  not null,
  cantidad_fisica      integer not null default 0,
  cantidad_reservada   integer not null default 0,
  cantidad_disponible  integer generated always as (cantidad_fisica - cantidad_reservada) stored,
  cantidad_minima      integer not null default 0,
  version_concurrencia bigint  not null default 1,
  creado_en            timestamptz not null default now(),
  actualizado_en       timestamptz not null default now(),
  constraint pk_tbl_inventario primary key (producto_id, almacen_id),
  constraint fk_tbl_inventario__cat_productos foreign key (producto_id)
             references wms.cat_productos (id) on delete restrict,
  constraint fk_tbl_inventario__cat_almacenes foreign key (almacen_id)
             references wms.cat_almacenes (id) on delete restrict,
  -- Última línea de defensa contra sobreventa: ninguna ruta de código,
  -- ni un UPDATE manual, puede dejar existencia negativa.
  constraint ck_tbl_inventario__fisica_no_negativa    check (cantidad_fisica    >= 0),
  constraint ck_tbl_inventario__reservada_no_negativa check (cantidad_reservada >= 0),
  constraint ck_tbl_inventario__cobertura_reserva     check (cantidad_reservada <= cantidad_fisica),
  constraint ck_tbl_inventario__minima_no_negativa    check (cantidad_minima    >= 0)
);
create index ix_tbl_inventario__almacen on wms.tbl_inventario (almacen_id, producto_id);
create index ix_tbl_inventario__existencia_baja on wms.tbl_inventario (almacen_id, producto_id)
  where cantidad_fisica <= cantidad_minima;

create sequence wms.seq_tbl_ordenes as bigint minvalue 1;

create table wms.tbl_ordenes (
  id                   bigint generated always as identity,
  consecutivo          bigint not null default nextval('wms.seq_tbl_ordenes'),
  folio                text generated always as ('ORD-' || lpad(consecutivo::text, 8, '0')) stored,
  cliente_id           bigint not null,
  almacen_id           bigint not null,
  estatus              text   not null default 'BORRADOR',
  monto_total          numeric(16,2) not null default 0,
  notas                text,
  version_concurrencia bigint not null default 1,
  confirmado_en        timestamptz,
  enviado_en           timestamptz,
  cancelado_en         timestamptz,
  motivo_cancelacion   text,
  -- QUIÉN ejecutó cada transición. Una cancelación en BORRADOR no genera
  -- movimientos, así que sin estas columnas su autor desaparecería.
  -- Barrera de motor para una ruta que no genera movimiento de inventario:
  -- sin ella, un reintento del alta tras la purga a 48 h crearia una orden
  -- duplicada sin violar nada.
  id_operacion         text not null,
  creado_por_usuario_id     bigint not null,
  confirmado_por_usuario_id bigint,
  enviado_por_usuario_id    bigint,
  cancelado_por_usuario_id  bigint,
  creado_en            timestamptz not null default now(),
  actualizado_en       timestamptz not null default now(),
  constraint pk_tbl_ordenes primary key (id),
  constraint fk_tbl_ordenes__confirmado_por foreign key (confirmado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint fk_tbl_ordenes__enviado_por    foreign key (enviado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint fk_tbl_ordenes__cancelado_por  foreign key (cancelado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint fk_tbl_ordenes__cat_clientes  foreign key (cliente_id)
             references wms.cat_clientes (id) on delete restrict,
  constraint fk_tbl_ordenes__cat_almacenes foreign key (almacen_id)
             references wms.cat_almacenes (id) on delete restrict,
  constraint fk_tbl_ordenes__cat_usuarios  foreign key (creado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint uq_tbl_ordenes__folio       unique (folio),
  constraint uq_tbl_ordenes__consecutivo unique (consecutivo),
  constraint ck_tbl_ordenes__estatus     check (estatus in ('BORRADOR','CONFIRMADA','ENVIADA','CANCELADA')),
  constraint ck_tbl_ordenes__total_no_negativo check (monto_total >= 0),
  constraint ck_tbl_ordenes__sello_cancelacion check ((estatus = 'CANCELADA') = (cancelado_en is not null)),
  constraint ck_tbl_ordenes__sello_confirmacion check (
             estatus <> 'CONFIRMADA' or (confirmado_en is not null and confirmado_por_usuario_id is not null)),
  constraint ck_tbl_ordenes__sello_envio check (
             estatus <> 'ENVIADA' or (enviado_en is not null and confirmado_en is not null
                                      and enviado_por_usuario_id is not null)),
  constraint ck_tbl_ordenes__autor_cancelacion check (
             (cancelado_en is null) = (cancelado_por_usuario_id is null))
);
create unique index ux_tbl_ordenes__operacion on wms.tbl_ordenes (id_operacion);
create index ix_tbl_ordenes__estatus_fecha on wms.tbl_ordenes (estatus, creado_en desc);
create index ix_tbl_ordenes__cliente       on wms.tbl_ordenes (cliente_id, creado_en desc);
create index ix_tbl_ordenes__almacen       on wms.tbl_ordenes (almacen_id, creado_en desc);

-- Partidas de la orden. Entidad asociativa: relaciona orden y producto,
-- carga atributos propios y muere con la orden (CASCADE) => prefijo rel_.
-- El precio y el nombre se congelan al alta: cambiar el catálogo jamás
-- reescribe una orden ya capturada. El SKU NO se congela porque es
-- inmutable por diseño; se resuelve por join en vw_orden_partidas.
create table wms.rel_orden_producto (
  id                        bigint generated always as identity,
  orden_id                  bigint  not null,
  producto_id               bigint  not null,
  nombre_historico          text    not null,
  cantidad                  integer not null,
  precio_unitario_historico numeric(14,2) not null,
  importe_linea             numeric(16,2) generated always as
                            (cantidad * precio_unitario_historico) stored,
  creado_en                 timestamptz not null default now(),
  constraint pk_rel_orden_producto primary key (id),
  constraint fk_rel_orden_producto__tbl_ordenes   foreign key (orden_id)
             references wms.tbl_ordenes (id) on delete cascade,
  constraint fk_rel_orden_producto__cat_productos foreign key (producto_id)
             references wms.cat_productos (id) on delete restrict,
  constraint uq_rel_orden_producto__orden_producto unique (orden_id, producto_id),
  constraint ck_rel_orden_producto__cantidad_positiva check (cantidad > 0),
  constraint ck_rel_orden_producto__precio_no_negativo check (precio_unitario_historico >= 0)
);
create index ix_rel_orden_producto__producto on wms.rel_orden_producto (producto_id);

create table wms.tbl_lotes_importacion (
  id                 bigint generated always as identity,
  nombre_archivo     text not null,
  tipo_lote          text not null,
  modo               text not null default 'SOLO_ALTA',
  estatus            text not null default 'PROCESANDO',
  renglones_total    integer not null default 0,
  renglones_ok       integer not null default 0,
  renglones_error    integer not null default 0,
  -- NOT NULL y unico: un reintento de importacion debe REANUDAR el lote
  -- existente, no crear uno nuevo con llaves por renglon frescas que no
  -- colisionarian con los renglones ya aplicados.
  id_operacion       text not null,
  creado_por_usuario_id bigint not null,
  iniciado_en        timestamptz not null default now(),
  finalizado_en      timestamptz,
  constraint pk_tbl_lotes_importacion primary key (id),
  constraint fk_tbl_lotes_importacion__cat_usuarios foreign key (creado_por_usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint ck_tbl_lotes_importacion__tipo    check (tipo_lote in ('PRODUCTOS','INVENTARIO','COMBINADO')),
  constraint ck_tbl_lotes_importacion__modo    check (modo in ('SOLO_ALTA','ALTA_O_ACTUALIZA')),
  constraint ck_tbl_lotes_importacion__estatus check (
             estatus in ('PROCESANDO','COMPLETADO','COMPLETADO_CON_ERRORES','FALLIDO')),
  constraint ck_tbl_lotes_importacion__conteos check (
             renglones_total >= 0 and renglones_ok >= 0 and renglones_error >= 0
             and renglones_ok + renglones_error <= renglones_total)
);
create index ix_tbl_lotes_importacion__fecha on wms.tbl_lotes_importacion (iniciado_en desc);
create unique index ux_tbl_lotes_importacion__operacion
  on wms.tbl_lotes_importacion (id_operacion);

create table wms.tbl_renglones_importacion (
  id                bigint generated always as identity,
  lote_id           bigint  not null,
  numero_renglon    integer not null,
  carga_original    jsonb   not null,
  estatus           text    not null,
  accion            text,
  codigo_error      text,
  mensaje_error     text,
  producto_id       bigint,
  almacen_id        bigint,
  cantidad_aplicada integer,
  movimiento_id     bigint,
  constraint pk_tbl_renglones_importacion primary key (id),
  constraint fk_tbl_renglones_importacion__lotes foreign key (lote_id)
             references wms.tbl_lotes_importacion (id) on delete cascade,
  -- RESTRICT y no SET NULL: perder a qué producto se aplicó un renglón
  -- rompería la trazabilidad histórica que exige la especificación.
  constraint fk_tbl_renglones_importacion__productos foreign key (producto_id)
             references wms.cat_productos (id) on delete restrict,
  constraint fk_tbl_renglones_importacion__almacenes foreign key (almacen_id)
             references wms.cat_almacenes (id) on delete restrict,
  constraint uq_tbl_renglones_importacion__renglon unique (lote_id, numero_renglon),
  constraint ck_tbl_renglones_importacion__estatus check (estatus in ('OK','ERROR','OMITIDO')),
  constraint ck_tbl_renglones_importacion__accion  check (
             accion is null or accion in ('ALTA','ACTUALIZACION','OMISION','SIN_CAMBIO')),
  -- Un renglón OMITIDO también debe poder explicar por qué, con un código
  -- estable que el frontend pueda agrupar sin parsear español.
  constraint ck_tbl_renglones_importacion__codigo_error check (
             (estatus = 'OK' and codigo_error is null)
          or (estatus in ('ERROR','OMITIDO') and codigo_error is not null))
);
create index ix_tbl_renglones_importacion__estatus  on wms.tbl_renglones_importacion (lote_id, estatus);
create index ix_tbl_renglones_importacion__producto on wms.tbl_renglones_importacion (producto_id)
  where producto_id is not null;
create index ix_tbl_renglones_importacion__almacen  on wms.tbl_renglones_importacion (almacen_id)
  where almacen_id is not null;

-- Bitácora de movimientos. Solo inserción, jamás UPDATE ni DELETE.
-- Doble cubeta: una confirmación mueve reserva sin mover físico; un embarque
-- mueve ambas. Una bitácora de una sola columna no puede representar eso.
create table wms.tbl_movimientos_inventario (
  id                  bigint generated always as identity,
  -- Identificador público y estable del movimiento. El cliente lo usa para
  -- correlacionar sin exponer el consecutivo interno.
  uuid_movimiento     uuid    not null default gen_random_uuid(),
  producto_id         bigint  not null,
  almacen_id          bigint  not null,
  tipo_movimiento     text    not null,
  delta_fisica        integer not null,
  fisica_antes        integer not null,
  fisica_despues      integer not null,
  delta_reservada     integer not null default 0,
  reservada_antes     integer not null default 0,
  reservada_despues   integer not null default 0,
  tipo_origen         text    not null default 'MANUAL',
  orden_id            bigint,
  lote_importacion_id bigint,
  -- Identidad de la OPERACIÓN de negocio que produjo este movimiento.
  -- NOT NULL a propósito: ningún movimiento puede existir sin poder decir de
  -- qué intención del usuario provino.
  id_operacion        text    not null,
  motivo              text,
  -- QUIÉN y CUÁNDO. RESTRICT: un operador dado de baja lógicamente sigue
  -- siendo resoluble desde cualquier movimiento histórico suyo.
  usuario_id          bigint  not null,
  creado_en           timestamptz not null default now(),
  constraint pk_tbl_movimientos_inventario primary key (id),
  constraint uq_tbl_movimientos_inventario__uuid unique (uuid_movimiento),
  constraint fk_tbl_movimientos_inventario__cat_usuarios foreign key (usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint fk_tbl_movimientos_inventario__tbl_inventario foreign key (producto_id, almacen_id)
             references wms.tbl_inventario (producto_id, almacen_id) on delete restrict,
  constraint fk_tbl_movimientos_inventario__tbl_ordenes foreign key (orden_id)
             references wms.tbl_ordenes (id) on delete restrict,
  constraint fk_tbl_movimientos_inventario__tbl_lotes_importacion foreign key (lote_importacion_id)
             references wms.tbl_lotes_importacion (id) on delete restrict,
  constraint ck_tbl_movimientos_inventario__tipo check (tipo_movimiento in
             ('ENTRADA','SALIDA','AJUSTE','RESERVA','LIBERACION','EMBARQUE','IMPORTACION')),
  constraint ck_tbl_movimientos_inventario__origen check (tipo_origen in
             ('AJUSTE_RAPIDO','ORDEN','IMPORTACION','MANUAL','SEMILLA')),
  constraint ck_tbl_movimientos_inventario__delta_no_nulo check (
             delta_fisica <> 0 or delta_reservada <> 0),
  constraint ck_tbl_movimientos_inventario__aritmetica_fisica check (
             fisica_despues = fisica_antes + delta_fisica),
  constraint ck_tbl_movimientos_inventario__aritmetica_reserva check (
             reservada_despues = reservada_antes + delta_reservada),
  constraint ck_tbl_movimientos_inventario__no_negativo check (
             fisica_despues >= 0 and reservada_despues >= 0),
  -- Ningún renglón puede mentir sobre su naturaleza: si no movió físico,
  -- forzosamente es una reserva o una liberación.
  constraint ck_tbl_movimientos_inventario__tipo_vs_delta check (
             (tipo_movimiento in ('RESERVA','LIBERACION')) = (delta_fisica = 0)),
  -- Referencia tipada, no polimórfica: cada origen apunta a su tabla real.
  constraint ck_tbl_movimientos_inventario__coherencia_origen check (
             (tipo_origen = 'ORDEN'       and orden_id is not null and lote_importacion_id is null)
          or (tipo_origen = 'IMPORTACION' and lote_importacion_id is not null and orden_id is null)
          or (tipo_origen in ('AJUSTE_RAPIDO','MANUAL','SEMILLA')
              and orden_id is null and lote_importacion_id is null))
);
create index ix_tbl_movimientos_inventario__inventario_fecha
  on wms.tbl_movimientos_inventario (producto_id, almacen_id, creado_en desc);
create index ix_tbl_movimientos_inventario__fecha
  on wms.tbl_movimientos_inventario (creado_en desc);
-- "Qué hizo el usuario X y cuándo": consulta de auditoría de primer orden.
create index ix_tbl_movimientos_inventario__usuario_fecha
  on wms.tbl_movimientos_inventario (usuario_id, creado_en desc);
create index ix_tbl_movimientos_inventario__orden
  on wms.tbl_movimientos_inventario (orden_id) where orden_id is not null;
create index ix_tbl_movimientos_inventario__lote
  on wms.tbl_movimientos_inventario (lote_importacion_id) where lote_importacion_id is not null;
-- =====================================================================
--  LA GARANTÍA DEFINITIVA DE IDEMPOTENCIA
-- =====================================================================
-- Este índice es el punto en el que "una operación del usuario = un solo
-- movimiento aplicado" deja de ser una convención de la capa de aplicación y
-- pasa a ser una imposibilidad física.
--
-- Es a NIVEL DE RENGLÓN, no de operación, porque una sola operación produce N
-- movimientos: confirmar una orden de tres partidas escribe tres renglones,
-- todos con el mismo id_operacion pero distinto producto. La unicidad de la
-- OPERACIÓN vive en pk_tbl_operaciones.
--
-- Como el trigger trg_tbl_inventario__bitacora escribe en esta tabla DENTRO
-- de la misma transacción que muta tbl_inventario, la violación de este
-- índice aborta también la mutación de existencia. No hay forma de aplicar
-- dos veces la misma operación: ni por doble clic, ni por reintento de
-- timeout, ni por dos peticiones simultáneas, ni por un bug de la aplicación,
-- ni por SQL manual.
create unique index ux_tbl_movimientos_inventario__operacion
  on wms.tbl_movimientos_inventario (id_operacion, producto_id, almacen_id, tipo_movimiento);
-- No se crea un índice adicional sobre id_operacion sola: el único anterior ya
-- la lleva como columna principal y sirve para "¿qué produjo esta operación?".

comment on column wms.tbl_movimientos_inventario.id_operacion is
  'Identidad de la operación de negocio. Referencia documental (sin FK) a tbl_operaciones.id_operacion: la bitácora es permanente y las operaciones se purgan a las 48 h, así que una FK impediría el purgado. La unicidad que importa es ux_tbl_movimientos_inventario__operacion, que no depende de esa tabla.';

-- Registro de OPERACIONES. Una operación es una intención del usuario, no una
-- petición HTTP: se acuña una sola vez cuando el usuario forma la intención y
-- se reutiliza en TODOS los reenvíos de esa misma intención (reintento por
-- timeout, segundo clic sobre el botón de un modal, reintento del navegador).
--
-- Infraestructura de protocolo, no dato de negocio: ninguno de los tres
-- prefijos le queda natural. Se clasifica tbl_ por ser transaccional (una fila
-- por operación). Caso señalado.
--
-- Esta tabla es el PRIMER filtro. El filtro definitivo e ineludible es el
-- índice único de tbl_movimientos_inventario sobre
-- (id_operacion, producto_id, almacen_id, tipo_movimiento): aunque la lógica
-- de aplicación fallara por completo, el segundo intento de materializar la
-- misma operación choca contra ese índice, el trigger de bitácora aborta y la
-- transacción entera —incluida la mutación de tbl_inventario— se revierte.
--
-- IMPORTANTE: la fila se inserta y COMMITEA en una conexión aparte, ANTES de
-- abrir la transacción de trabajo. Si viviera dentro de esa transacción sería
-- invisible para las peticiones concurrentes (MVCC) y dos reenvíos simultáneos
-- de la misma operación no se verían el uno al otro.
create table wms.tbl_operaciones (
  id_operacion     text not null,
  -- Identifica el CONTROL de la UI sobre el que se opera, para diagnóstico y
  -- para el barrido. Ej: 'ajuste:producto=12:almacen=3'.
  alcance          text not null,
  ruta             text not null,
  -- Huella del cuerpo canonicalizado. Si llega la misma operación con carga
  -- distinta es un error del cliente, no un reintento: se rechaza con WM015.
  hash_peticion    text not null,
  estatus          text not null default 'EN_PROCESO',
  intentos         integer not null default 1,
  codigo_respuesta integer,
  cuerpo_respuesta jsonb,
  usuario_id       bigint not null,
  creado_en        timestamptz not null default now(),
  completado_en    timestamptz,
  expira_en        timestamptz not null default now() + interval '48 hours',
  constraint pk_tbl_operaciones primary key (id_operacion),
  constraint fk_tbl_operaciones__cat_usuarios foreign key (usuario_id)
             references wms.cat_usuarios (id) on delete restrict,
  constraint ck_tbl_operaciones__estatus check (
             estatus in ('EN_PROCESO','COMPLETADO','FALLIDO')),
  constraint ck_tbl_operaciones__sello_cierre check (
             (estatus = 'EN_PROCESO') = (completado_en is null)),
  constraint ck_tbl_operaciones__respuesta_completada check (
             estatus <> 'COMPLETADO' or codigo_respuesta is not null),
  constraint ck_tbl_operaciones__intentos check (intentos >= 1),
  -- El id lleva SIEMPRE el operador como primer segmento. Sin ese espacio de
  -- nombres, dos operadores que acuñen el mismo id con cuerpos idénticos
  -- producen el mismo hash: el segundo recibiría 200 con la respuesta del
  -- primero y su movimiento desaparecería sin error. El CHECK convierte la
  -- convención del cliente en un invariante del motor.
  constraint ck_tbl_operaciones__formato check (
             id_operacion ~ '^[0-9]{1,19}:[A-Za-z0-9._:-]{8,108}$'),
  constraint ck_tbl_operaciones__prefijo_actor check (
             split_part(id_operacion, ':', 1) = usuario_id::text)
);
create index ix_tbl_operaciones__expira  on wms.tbl_operaciones (expira_en);
create index ix_tbl_operaciones__alcance on wms.tbl_operaciones (alcance, creado_en desc);
create index ix_tbl_operaciones__usuario on wms.tbl_operaciones (usuario_id, creado_en desc);
-- Barrido de operaciones colgadas (proceso muerto entre reserva y trabajo).
create index ix_tbl_operaciones__en_proceso
  on wms.tbl_operaciones (creado_en) where estatus = 'EN_PROCESO';
