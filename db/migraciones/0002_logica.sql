-- =====================================================================
--  Mini WMS + Órdenes  ·  0002 · Funciones, triggers y vistas
-- ---------------------------------------------------------------------
--  Los SQLSTATE de la clase WM son propios del sistema y permiten a .NET
--  mapear cada error de negocio a su HTTP sin hacer string-matching sobre
--  mensajes en español. Los SQLSTATE estándar (40001, 40P01, 23505, 23503,
--  57014) se dejan intactos para que Npgsql los clasifique como corresponde.
-- =====================================================================

-- =====================================================================
--  UTILITARIOS
-- =====================================================================

create or replace function wms.fn_tocar_actualizado_en()
returns trigger language plpgsql as $$
begin
  new.actualizado_en := now();
  return new;
end $$;

create or replace function wms.fn_incrementar_version_concurrencia()
returns trigger language plpgsql as $$
begin
  new.version_concurrencia := old.version_concurrencia + 1;
  new.actualizado_en := now();
  return new;
end $$;

-- Sella la baja lógica: quien desactiva un registro queda registrado con
-- fecha, sin depender de que la capa de aplicación se acuerde de hacerlo.
create or replace function wms.fn_sellar_baja_logica()
returns trigger language plpgsql as $$
declare v_vigente_antes boolean; v_vigente_ahora boolean;
begin
  if tg_argv[0] = 'estatus' then
     -- En INSERT no hay OLD: se asume que "antes" no existia y por tanto
     -- estaba vigente, de modo que nacer inactivo tambien queda sellado.
     -- Sin esta rama, dar de alta una entidad ya inactiva violaba
     -- ck_..._sello_baja y no habia forma de importarla.
     v_vigente_antes := (tg_op = 'INSERT') or (old.estatus = 'ACTIVO');
     v_vigente_ahora := (new.estatus = 'ACTIVO');
  else
     v_vigente_antes := (tg_op = 'INSERT') or old.es_activo;
     v_vigente_ahora := new.es_activo;
  end if;

  if v_vigente_antes and not v_vigente_ahora then
     -- La fecha la pone el motor, no el cliente: un sello con fecha
     -- arbitraria no es un sello.
     new.desactivado_en := now();
     new.desactivado_por_usuario_id := coalesce(
        new.desactivado_por_usuario_id,
        nullif(current_setting('wms.ctx_usuario_id', true), '')::bigint);
     if new.desactivado_por_usuario_id is null then
        raise exception 'Desactivar un registro exige declarar el usuario responsable'
          using errcode = 'WM014';
     end if;
  end if;
  -- Reactivar NO limpia el sello: la baja anterior ocurrió y su rastro
  -- (quién y cuándo) debe sobrevivir. El CHECK es unidireccional justo
  -- para permitirlo.
  return new;
end $$;

create trigger trg_cat_usuarios__actualizado before update on wms.cat_usuarios
  for each row execute function wms.fn_tocar_actualizado_en();
create trigger trg_cat_categorias__actualizado before update on wms.cat_categorias
  for each row execute function wms.fn_tocar_actualizado_en();
create trigger trg_cat_almacenes__actualizado  before update on wms.cat_almacenes
  for each row execute function wms.fn_tocar_actualizado_en();
create trigger trg_cat_clientes__actualizado   before update on wms.cat_clientes
  for each row execute function wms.fn_tocar_actualizado_en();
create trigger trg_cat_productos__actualizado  before update on wms.cat_productos
  for each row execute function wms.fn_incrementar_version_concurrencia();
create trigger trg_tbl_ordenes__actualizado    before update on wms.tbl_ordenes
  for each row execute function wms.fn_incrementar_version_concurrencia();

-- 'baja_' ordena alfabéticamente antes que cualquier otro trigger BEFORE de
-- estas tablas, de modo que el sello se aplica sobre el NEW original.
-- 'OF <columna>' solo restringe al UPDATE; el INSERT siempre dispara.
create trigger trg_cat_usuarios__baja_logica
  before insert or update of es_activo on wms.cat_usuarios
  for each row execute function wms.fn_sellar_baja_logica('es_activo');
create trigger trg_cat_categorias__baja_logica
  before insert or update of es_activo on wms.cat_categorias
  for each row execute function wms.fn_sellar_baja_logica('es_activo');
create trigger trg_cat_almacenes__baja_logica
  before insert or update of es_activo on wms.cat_almacenes
  for each row execute function wms.fn_sellar_baja_logica('es_activo');
create trigger trg_cat_clientes__baja_logica
  before insert or update of es_activo on wms.cat_clientes
  for each row execute function wms.fn_sellar_baja_logica('es_activo');
create trigger trg_cat_productos__baja_logica
  before insert or update of estatus on wms.cat_productos
  for each row execute function wms.fn_sellar_baja_logica('estatus');

-- =====================================================================
--  ACUÑACIÓN E INMUTABILIDAD DEL SKU
-- =====================================================================

-- Acuñación autorreparable. El consecutivo se calcula contra la realidad
-- (max en cat_productos), no contra un contador que pudo quedar atrás por
-- un rollback, una semilla o un restore. El UPDATE sobre cat_categorias
-- toma el row lock, de modo que dos altas simultáneas en la misma categoría
-- se serializan y jamás obtienen el mismo folio.
create or replace function wms.fn_acunar_sku_producto()
returns trigger language plpgsql as $$
declare v_patron text;
begin
  if new.sku_prefijo is null then
     select codigo into strict new.sku_prefijo
       from wms.cat_categorias where id = new.categoria_id;
  end if;

  if new.sku_consecutivo is null then
     update wms.cat_categorias c
        set consecutivo_sku = greatest(
              c.consecutivo_sku,
              coalesce((select max(p.sku_consecutivo)
                          from wms.cat_productos p
                         where p.sku_prefijo = c.codigo), 0)
            ) + 1
      where c.codigo = new.sku_prefijo
      returning c.consecutivo_sku into strict new.sku_consecutivo;
  else
     if exists (select 1 from wms.cat_productos p
                 where p.sku_prefijo = new.sku_prefijo
                   and p.sku_consecutivo = new.sku_consecutivo) then
        raise exception 'El SKU % ya existe',
          new.sku_prefijo || '-' || lpad(new.sku_consecutivo::text, 4, '0')
          using errcode = 'WM004';
     end if;
  end if;

  select patron_completo into v_patron from wms.cat_reglas_sku where es_activo;
  if v_patron is not null
     and (new.sku_prefijo || '-' || lpad(new.sku_consecutivo::text, 4, '0')) !~ v_patron then
     raise exception 'El SKU generado no cumple la regla activa %', v_patron
       using errcode = 'WM009';
  end if;
  return new;
end $$;

create trigger trg_cat_productos__acunar_sku before insert on wms.cat_productos
  for each row execute function wms.fn_acunar_sku_producto();

create or replace function wms.fn_sincronizar_consecutivo_sku()
returns trigger language plpgsql as $$
begin
  update wms.cat_categorias
     set consecutivo_sku = new.sku_consecutivo
   where codigo = new.sku_prefijo
     and consecutivo_sku < new.sku_consecutivo;
  return null;
end $$;

create trigger trg_cat_productos__sincronizar_consecutivo after insert on wms.cat_productos
  for each row execute function wms.fn_sincronizar_consecutivo_sku();

create or replace function wms.fn_bloquear_cambio_sku()
returns trigger language plpgsql as $$
begin
  if new.sku_prefijo is distinct from old.sku_prefijo
     or new.sku_consecutivo is distinct from old.sku_consecutivo then
     raise exception 'El SKU % no puede reasignarse', old.sku using errcode = 'WM003';
  end if;
  return new;
end $$;

create trigger trg_cat_productos__sku_inmutable before update on wms.cat_productos
  for each row execute function wms.fn_bloquear_cambio_sku();

-- =====================================================================
--  CONTEXTO DE OPERACIÓN
-- =====================================================================
-- El trigger de bitácora no sabe POR QUÉ ni QUIÉN cambió la existencia.
-- El contexto viaja en GUC locales de transacción que las funciones de
-- negocio fijan ANTES y limpian DESPUÉS: sin la limpieza, una segunda
-- escritura en la misma transacción heredaría el contexto de la primera y
-- la bitácora registraría un hecho falso e inmutable.

create or replace function wms.fn_fijar_contexto_movimiento(
  p_tipo_movimiento text, p_tipo_origen text, p_orden_id bigint, p_lote_id bigint,
  p_id_operacion text, p_motivo text, p_usuario_id bigint)
returns void language plpgsql as $$
declare v_activo boolean;
begin
  -- Sin id_operacion no hay idempotencia posible: se rechaza de entrada en vez
  -- de dejar que falle más tarde el NOT NULL de la bitácora.
  if p_id_operacion is null or btrim(p_id_operacion) = '' then
     raise exception 'Toda mutación de inventario debe declarar su id_operacion'
       using errcode = 'WM012';
  end if;
  if p_usuario_id is null then
     raise exception 'Toda mutación de inventario debe declarar el usuario responsable'
       using errcode = 'WM014';
  end if;
  select es_activo into v_activo from wms.cat_usuarios where id = p_usuario_id;
  if v_activo is null then
     raise exception 'El usuario % no existe', p_usuario_id using errcode = 'WM014';
  end if;
  if not v_activo then
     raise exception 'El usuario % está inactivo', p_usuario_id using errcode = 'WM014';
  end if;

  perform set_config('wms.ctx_tipo_movimiento', p_tipo_movimiento, true);
  perform set_config('wms.ctx_tipo_origen',     p_tipo_origen,     true);
  perform set_config('wms.ctx_orden_id',        coalesce(p_orden_id::text, ''), true);
  perform set_config('wms.ctx_lote_id',         coalesce(p_lote_id::text, ''),  true);
  perform set_config('wms.ctx_id_operacion',    p_id_operacion,                 true);
  perform set_config('wms.ctx_motivo',          coalesce(p_motivo, ''),         true);
  perform set_config('wms.ctx_usuario_id',      p_usuario_id::text,             true);
end $$;

create or replace function wms.fn_limpiar_contexto_movimiento()
returns void language plpgsql as $$
begin
  perform set_config('wms.ctx_tipo_movimiento', '', true);
  perform set_config('wms.ctx_tipo_origen',     '', true);
  perform set_config('wms.ctx_orden_id',        '', true);
  perform set_config('wms.ctx_lote_id',         '', true);
  perform set_config('wms.ctx_id_operacion',    '', true);
  perform set_config('wms.ctx_motivo',          '', true);
  -- wms.ctx_usuario_id NO se limpia: identifica la sesión completa y lo
  -- necesitan también los triggers de baja lógica de los catálogos.
end $$;

-- =====================================================================
--  BITÁCORA AUTOMÁTICA DE INVENTARIO
-- =====================================================================
-- Un movimiento por operación y por usuario. Nunca se acumula un valor sin
-- historial: 5 unidades del usuario A y 3 del usuario B son DOS renglones
-- independientes cuya suma reconstruye la existencia.

create or replace function wms.fn_registrar_movimiento_inventario()
returns trigger language plpgsql as $$
declare v_df int; v_dr int; v_usuario bigint; v_operacion text;
begin
  if tg_op = 'INSERT' then
     v_df := new.cantidad_fisica;                          v_dr := new.cantidad_reservada;
  else
     v_df := new.cantidad_fisica    - old.cantidad_fisica;
     v_dr := new.cantidad_reservada - old.cantidad_reservada;
  end if;

  -- Alta de la fila en ceros: no es un movimiento.
  if v_df = 0 and v_dr = 0 then return null; end if;

  v_usuario := nullif(current_setting('wms.ctx_usuario_id', true), '')::bigint;
  if v_usuario is null then
     raise exception 'No hay usuario en contexto: toda mutación de inventario debe ser atribuible'
       using errcode = 'WM014';
  end if;

  v_operacion := nullif(current_setting('wms.ctx_id_operacion', true), '');
  if v_operacion is null then
     raise exception 'No hay id_operacion en contexto: ninguna mutación de inventario puede quedar fuera del control de idempotencia'
       using errcode = 'WM012';
  end if;

  insert into wms.tbl_movimientos_inventario (
      producto_id, almacen_id, tipo_movimiento,
      delta_fisica, fisica_antes, fisica_despues,
      delta_reservada, reservada_antes, reservada_despues,
      tipo_origen, orden_id, lote_importacion_id,
      id_operacion, motivo, usuario_id)
  values (
      new.producto_id, new.almacen_id,
      coalesce(nullif(current_setting('wms.ctx_tipo_movimiento', true), ''),
               case when v_df > 0 then 'ENTRADA'
                    when v_df < 0 then 'SALIDA'
                    when v_dr > 0 then 'RESERVA'
                    else 'LIBERACION' end),
      v_df, coalesce(old.cantidad_fisica, 0),    new.cantidad_fisica,
      v_dr, coalesce(old.cantidad_reservada, 0), new.cantidad_reservada,
      coalesce(nullif(current_setting('wms.ctx_tipo_origen', true), ''), 'MANUAL'),
      nullif(current_setting('wms.ctx_orden_id', true), '')::bigint,
      nullif(current_setting('wms.ctx_lote_id',  true), '')::bigint,
      v_operacion,
      nullif(current_setting('wms.ctx_motivo', true), ''),
      v_usuario);
  return null;
end $$;

create trigger trg_tbl_inventario__bitacora
  after insert or update of cantidad_fisica, cantidad_reservada on wms.tbl_inventario
  for each row execute function wms.fn_registrar_movimiento_inventario();

-- La bitácora es de SOLO INSERCIÓN, sin excepciones. Un renglón mutable no
-- es una bitácora. El estado de un movimiento (aplicado / compensado /
-- consumido) se DERIVA en vw_movimientos_detalle, no se almacena.
create or replace function wms.fn_bloquear_mutacion_movimientos()
returns trigger language plpgsql as $$
begin
  raise exception 'La bitácora de movimientos es de solo inserción' using errcode = 'WM006';
end $$;

create trigger trg_tbl_movimientos_inventario__inmutable
  before update or delete on wms.tbl_movimientos_inventario
  for each row execute function wms.fn_bloquear_mutacion_movimientos();

-- TRUNCATE no dispara triggers de fila: se bloquea con su propio trigger de
-- sentencia. Sin esto, la bitácora "inmutable" se vacía con una sola orden.
create trigger trg_tbl_movimientos_inventario__sin_truncate
  before truncate on wms.tbl_movimientos_inventario
  for each statement execute function wms.fn_bloquear_mutacion_movimientos();

-- Las entidades transaccionales NO se borran. El CASCADE de partidas y
-- renglones existe para la integridad del modelo, no como puerta para
-- eliminar una orden en BORRADOR o un lote fallido sin dejar rastro.
create or replace function wms.fn_bloquear_borrado()
returns trigger language plpgsql as $$
begin
  raise exception 'Las entidades transaccionales no se borran: la baja es lógica'
    using errcode = 'WM006';
end $$;

create trigger trg_tbl_ordenes__sin_borrado before delete on wms.tbl_ordenes
  for each row execute function wms.fn_bloquear_borrado();
create trigger trg_tbl_lotes_importacion__sin_borrado before delete on wms.tbl_lotes_importacion
  for each row execute function wms.fn_bloquear_borrado();
create trigger trg_tbl_ordenes__sin_truncate before truncate on wms.tbl_ordenes
  for each statement execute function wms.fn_bloquear_borrado();
create trigger trg_tbl_inventario__sin_truncate before truncate on wms.tbl_inventario
  for each statement execute function wms.fn_bloquear_borrado();

-- =====================================================================
--  IDEMPOTENCIA POR OPERACIÓN
-- =====================================================================
-- Regla del sistema: UNA OPERACIÓN DEL USUARIO = UN SOLO MOVIMIENTO APLICADO.
--
-- El id_operacion lo acuña el cliente UNA vez, cuando el usuario forma la
-- intención (abre el modal, ajusta la cantidad), y lo reutiliza en todos los
-- reenvíos de esa misma intención. La garantía NO depende de eso: aunque el
-- cliente se comporte mal, ux_tbl_movimientos_inventario__operacion impide
-- físicamente materializar dos veces la misma operación.
--
-- La cancelación en el frontend es UX y ahorro de tráfico, nunca una garantía
-- de integridad: si la petición ya llegó y confirmó, abortarla no revierte
-- nada. Por eso la protección vive aquí y no allá.

-- FASE 0 — conexión aparte, COMMIT inmediato.
-- Devuelve el veredicto sin lanzar excepciones para los casos normales, de
-- modo que .NET decida el HTTP sin depender del texto del mensaje.
--   NUEVA           : reservada, hay que ejecutarla
--   EN_CURSO        : otro reenvío la está ejecutando ahora mismo    -> 409
--   YA_COMPLETADA   : ya se aplicó; devolver la respuesta almacenada -> 200
--   CARGA_DISTINTA  : mismo id con otro cuerpo, error del cliente    -> 409/WM015
create or replace function wms.fn_reservar_operacion(
  p_id_operacion text, p_alcance text, p_ruta text,
  p_hash_peticion text, p_usuario_id bigint)
returns table (veredicto text, codigo_respuesta integer, cuerpo_respuesta jsonb)
language plpgsql as $$
declare v_fila wms.tbl_operaciones;
begin
  -- El prefijo de actor se valida ANTES del INSERT. Si se dejara al CHECK,
  -- la violación saltaría antes de que el ON CONFLICT pudiera arbitrar y el
  -- llamador recibiría un 23514 crudo en vez de un veredicto. El CHECK sigue
  -- siendo el invariante de respaldo para cualquier otra ruta de escritura.
  if split_part(p_id_operacion, ':', 1) is distinct from p_usuario_id::text then
     return query select 'CONFLICTO_DE_ACTOR'::text, null::integer, null::jsonb;
     return;
  end if;

  insert into wms.tbl_operaciones (
      id_operacion, alcance, ruta, hash_peticion, usuario_id)
  values (p_id_operacion, p_alcance, p_ruta, p_hash_peticion, p_usuario_id)
  on conflict (id_operacion) do nothing;

  if found then
     return query select 'NUEVA'::text, null::integer, null::jsonb;
     return;
  end if;

  -- Ya existía. El FOR UPDATE serializa dos reenvíos simultáneos: el segundo
  -- espera aquí y observa un estado ya definido, nunca uno intermedio.
  select * into v_fila from wms.tbl_operaciones
   where id_operacion = p_id_operacion for update;

  -- Discriminador de actor. Sin él, dos operadores que acuñen el mismo id con
  -- cuerpos idénticos producirían el mismo hash y el segundo recibiría 200 con
  -- la respuesta del primero: su movimiento se perdería en silencio.
  if v_fila.usuario_id is distinct from p_usuario_id then
     return query select 'CONFLICTO_DE_ACTOR'::text, null::integer, null::jsonb;
     return;
  end if;

  -- Se comparan alcance y ruta ADEMÁS del hash. Comparar solo el hash es el
  -- espejo exacto de la doble aplicación: POST /ordenes/12/confirmar y
  -- POST /ordenes/12/enviar tienen ambos cuerpo vacío —el id va en la ruta—,
  -- así que con el mismo id el envío recibiría 200 con la respuesta de la
  -- confirmación, fn_enviar_orden no se invocaría nunca, y no habría embarque
  -- ni descuento de existencia ni error alguno.
  if v_fila.hash_peticion is distinct from p_hash_peticion
     or v_fila.alcance    is distinct from p_alcance
     or v_fila.ruta       is distinct from p_ruta then
     return query select 'CARGA_DISTINTA'::text, null::integer, null::jsonb;
     return;
  end if;

  if v_fila.estatus = 'COMPLETADO' then
     -- Reintento de una operación ya aplicada: se devuelve la MISMA respuesta
     -- y NO se vuelve a generar el movimiento.
     update wms.tbl_operaciones set intentos = intentos + 1
      where id_operacion = p_id_operacion;
     return query select 'YA_COMPLETADA'::text, v_fila.codigo_respuesta, v_fila.cuerpo_respuesta;
     return;
  end if;

  if v_fila.estatus = 'FALLIDO' then
     -- El intento anterior no aplicó nada: se puede reejecutar con el mismo id.
     update wms.tbl_operaciones
        set estatus = 'EN_PROCESO', completado_en = null,
            codigo_respuesta = null, cuerpo_respuesta = null,
            intentos = intentos + 1, creado_en = now()
      where id_operacion = p_id_operacion;
     return query select 'NUEVA'::text, null::integer, null::jsonb;
     return;
  end if;

  update wms.tbl_operaciones set intentos = intentos + 1
   where id_operacion = p_id_operacion;
  return query select 'EN_CURSO'::text, null::integer, null::jsonb;
end $$;

-- Cierra el sobre. Se invoca DENTRO de la transacción de trabajo, como última
-- sentencia antes del COMMIT: si el COMMIT falla, el sello se revierte con
-- todo lo demás y la operación sigue siendo reejecutable.
create or replace function wms.fn_sellar_operacion(
  p_id_operacion text, p_codigo integer, p_cuerpo jsonb)
returns void language plpgsql as $$
begin
  update wms.tbl_operaciones
     set estatus = 'COMPLETADO', completado_en = now(),
         codigo_respuesta = p_codigo, cuerpo_respuesta = p_cuerpo
   where id_operacion = p_id_operacion and estatus = 'EN_PROCESO';
  if not found then
     raise exception 'La operación % no está en curso', p_id_operacion using errcode = 'WM013';
  end if;
end $$;

-- FASE 2 — conexión aparte. La transacción de trabajo ya está abortada y no
-- admite más sentencias. Marcar FALLIDO deja la operación REEJECUTABLE con el
-- mismo id, que es lo correcto: no se aplicó nada.
create or replace function wms.fn_cerrar_operacion_fallida(
  p_id_operacion text, p_codigo integer, p_detalle text)
returns void language plpgsql as $$
begin
  update wms.tbl_operaciones
     set estatus = 'FALLIDO', completado_en = now(),
         codigo_respuesta = p_codigo,
         cuerpo_respuesta = jsonb_build_object('detalle', p_detalle)
   where id_operacion = p_id_operacion and estatus = 'EN_PROCESO';
end $$;

-- Barrido de operaciones colgadas: el proceso murió entre la reserva y el
-- trabajo, así que nada se aplicó y el id debe volver a ser utilizable.
-- Programar con pg_cron cada minuto.
create or replace function wms.fn_barrer_operaciones_colgadas(
  p_antiguedad interval default interval '5 minutes')
returns integer language plpgsql as $$
declare v_n integer;
begin
  -- Dos guardias, ambas necesarias:
  --   1. Nunca marcar FALLIDO una operación que YA dejó rastro en la bitácora:
  --      sería declarar no aplicado algo aplicado, y habilitaría su reejecución.
  --   2. La importación no entra: su avance vive en tbl_lotes_importacion y
  --      puede durar legítimamente más que el umbral.
  update wms.tbl_operaciones o
     set estatus = 'FALLIDO', completado_en = now(), codigo_respuesta = 500,
         cuerpo_respuesta = jsonb_build_object('detalle', 'Operación abandonada por el proceso')
   where o.estatus = 'EN_PROCESO'
     and o.creado_en < now() - p_antiguedad
     and o.alcance not like 'importacion:%'
     and not exists (select 1 from wms.tbl_movimientos_inventario m
                      where m.id_operacion = o.id_operacion);
  get diagnostics v_n = row_count;
  -- La purga respeta la misma regla: una lápida cuya operación dejó rastro
  -- pero quedó sin sellar no se borra, o su reenvío se trataría como nueva.
  delete from wms.tbl_operaciones o
   where o.expira_en < now()
     and (o.estatus <> 'EN_PROCESO'
          or not exists (select 1 from wms.tbl_movimientos_inventario m
                          where m.id_operacion = o.id_operacion));
  return v_n;
end $$;

-- =====================================================================
--  ÓRDENES
-- =====================================================================

create or replace function wms.fn_sellar_partida()
returns trigger language plpgsql as $$
begin
  select p.nombre, coalesce(new.precio_unitario_historico, p.precio_unitario)
    into strict new.nombre_historico, new.precio_unitario_historico
    from wms.cat_productos p where p.id = new.producto_id;
  return new;
end $$;

create trigger trg_rel_orden_producto__sellar before insert on wms.rel_orden_producto
  for each row execute function wms.fn_sellar_partida();

create or replace function wms.fn_bloquear_partidas_no_borrador()
returns trigger language plpgsql as $$
declare v_estatus text;
begin
  select estatus into v_estatus from wms.tbl_ordenes
   where id = coalesce(new.orden_id, old.orden_id);
  -- v_estatus nulo => la orden ya se está borrando en cascada: se permite.
  if v_estatus is not null and v_estatus <> 'BORRADOR' then
     raise exception 'La orden está en estatus % y sus partidas no son editables', v_estatus
       using errcode = 'WM007';
  end if;
  return coalesce(new, old);
end $$;

create trigger trg_rel_orden_producto__solo_borrador
  before insert or update or delete on wms.rel_orden_producto
  for each row execute function wms.fn_bloquear_partidas_no_borrador();

create or replace function wms.fn_recalcular_total_orden()
returns trigger language plpgsql as $$
declare v_orden bigint;
begin
  v_orden := coalesce(new.orden_id, old.orden_id);
  update wms.tbl_ordenes o
     set monto_total = coalesce(
         (select sum(r.importe_linea) from wms.rel_orden_producto r where r.orden_id = v_orden), 0)
   where o.id = v_orden;
  return null;
end $$;

create trigger trg_rel_orden_producto__total
  after insert or update or delete on wms.rel_orden_producto
  for each row execute function wms.fn_recalcular_total_orden();

-- monto_total es derivado. El guardián se autovalida: acepta cualquier
-- valor que coincida con la suma real de las partidas y rechaza los demás.
create or replace function wms.fn_validar_total_orden()
returns trigger language plpgsql as $$
begin
  if new.monto_total is distinct from old.monto_total
     and new.monto_total is distinct from coalesce(
         (select sum(r.importe_linea) from wms.rel_orden_producto r where r.orden_id = new.id), 0) then
     raise exception 'monto_total es derivado de las partidas y no admite escritura directa'
       using errcode = 'WM010';
  end if;
  return new;
end $$;

create trigger trg_tbl_ordenes__total_derivado before update of monto_total on wms.tbl_ordenes
  for each row execute function wms.fn_validar_total_orden();

-- Máquina de estados:
--   BORRADOR   -> CONFIRMADA | CANCELADA
--   CONFIRMADA -> ENVIADA    | CANCELADA
--   ENVIADA    -> (terminal)   CANCELADA -> (terminal)
create or replace function wms.fn_validar_transicion_orden()
returns trigger language plpgsql as $$
begin
  if new.estatus = old.estatus then return new; end if;
  if not (
       (old.estatus = 'BORRADOR'   and new.estatus in ('CONFIRMADA','CANCELADA'))
    or (old.estatus = 'CONFIRMADA' and new.estatus in ('ENVIADA','CANCELADA'))
     ) then
     raise exception 'Transición % -> % no permitida', old.estatus, new.estatus
       using errcode = 'WM001';
  end if;
  return new;
end $$;

create trigger trg_tbl_ordenes__transicion before update of estatus on wms.tbl_ordenes
  for each row execute function wms.fn_validar_transicion_orden();

create or replace function wms.fn_bloquear_encabezado_no_borrador()
returns trigger language plpgsql as $$
begin
  if old.estatus <> 'BORRADOR'
     and (new.almacen_id is distinct from old.almacen_id
       or new.cliente_id is distinct from old.cliente_id) then
     raise exception 'Almacén y cliente son inmutables en estatus %', old.estatus
       using errcode = 'WM007';
  end if;
  return new;
end $$;

create trigger trg_tbl_ordenes__encabezado_inmutable before update on wms.tbl_ordenes
  for each row execute function wms.fn_bloquear_encabezado_no_borrador();

-- =====================================================================
--  PRIMITIVAS ATÓMICAS DE INVENTARIO
-- =====================================================================

-- Ajuste de existencia. El UPDATE de una sola sentencia toma el row lock y
-- re-evalúa la fila tras esperar: NO existe lost update aunque N usuarios
-- escriban a la vez, porque el delta es conmutativo y cada uno deja su
-- propio renglón en la bitácora.
create or replace function wms.fn_ajustar_existencia(
  p_producto_id bigint, p_almacen_id bigint, p_delta integer,
  p_tipo_movimiento text, p_usuario_id bigint, p_id_operacion text,
  p_tipo_origen text default 'AJUSTE_RAPIDO',
  p_orden_id bigint default null, p_lote_id bigint default null,
  p_motivo text default null,
  p_version_esperada bigint default null
) returns wms.tbl_inventario language plpgsql as $$
declare v_row wms.tbl_inventario;
begin
  if p_delta = 0 then
     raise exception 'El delta de un ajuste no puede ser cero' using errcode = 'WM012';
  end if;

  perform wms.fn_fijar_contexto_movimiento(
    p_tipo_movimiento, p_tipo_origen, p_orden_id, p_lote_id, p_id_operacion, p_motivo, p_usuario_id);

  insert into wms.tbl_inventario (producto_id, almacen_id)
  values (p_producto_id, p_almacen_id)
  on conflict (producto_id, almacen_id) do nothing;

  update wms.tbl_inventario
     set cantidad_fisica      = cantidad_fisica + p_delta,
         version_concurrencia = version_concurrencia + 1,
         actualizado_en       = now()
   where producto_id = p_producto_id and almacen_id = p_almacen_id
     and (p_version_esperada is null or version_concurrencia = p_version_esperada)
     and cantidad_fisica + p_delta >= cantidad_reservada
  returning * into v_row;

  if not found then
     if exists (select 1 from wms.tbl_inventario
                 where producto_id = p_producto_id and almacen_id = p_almacen_id
                   and (p_version_esperada is null or version_concurrencia = p_version_esperada)) then
        raise exception 'Existencia insuficiente del producto % en el almacén %',
          p_producto_id, p_almacen_id using errcode = 'WM002';
     end if;
     raise exception 'La versión enviada ya no es vigente' using errcode = 'WM008';
  end if;

  perform wms.fn_limpiar_contexto_movimiento();
  return v_row;
end $$;

create or replace function wms.fn_confirmar_orden(
  p_orden_id bigint, p_usuario_id bigint, p_id_operacion text)
returns wms.tbl_ordenes language plpgsql as $$
declare v_orden wms.tbl_ordenes; r record;
begin
  select * into strict v_orden from wms.tbl_ordenes where id = p_orden_id for update;
  if v_orden.estatus <> 'BORRADOR' then
     raise exception 'La orden está en estatus %', v_orden.estatus using errcode = 'WM001';
  end if;
  if not exists (select 1 from wms.rel_orden_producto where orden_id = p_orden_id) then
     raise exception 'La orden no tiene partidas' using errcode = 'WM011';
  end if;

  perform wms.fn_fijar_contexto_movimiento(
    'RESERVA', 'ORDEN', p_orden_id, null, p_id_operacion, 'Confirmación de orden', p_usuario_id);

  -- ORDER BY producto_id: orden determinista de adquisición de locks.
  -- Sin esto, dos órdenes con los mismos productos en distinto orden se
  -- bloquearían mutuamente y Postgres abortaría una con 40P01.
  for r in select producto_id, cantidad from wms.rel_orden_producto
            where orden_id = p_orden_id order by producto_id
  loop
     update wms.tbl_inventario
        set cantidad_reservada   = cantidad_reservada + r.cantidad,
            version_concurrencia = version_concurrencia + 1,
            actualizado_en       = now()
      where producto_id = r.producto_id and almacen_id = v_orden.almacen_id
        and cantidad_fisica - cantidad_reservada >= r.cantidad;
     if not found then
        if exists (select 1 from wms.tbl_inventario
                    where producto_id = r.producto_id and almacen_id = v_orden.almacen_id) then
           raise exception 'Existencia insuficiente del producto % en el almacén %',
             r.producto_id, v_orden.almacen_id using errcode = 'WM002';
        end if;
        raise exception 'El producto % no tiene inventario en el almacén %',
          r.producto_id, v_orden.almacen_id using errcode = 'WM005';
     end if;
  end loop;

  update wms.tbl_ordenes
     set estatus = 'CONFIRMADA', confirmado_en = now(),
         confirmado_por_usuario_id = p_usuario_id
   where id = p_orden_id returning * into v_orden;

  perform wms.fn_limpiar_contexto_movimiento();
  return v_orden;
end $$;

create or replace function wms.fn_enviar_orden(
  p_orden_id bigint, p_usuario_id bigint, p_id_operacion text)
returns wms.tbl_ordenes language plpgsql as $$
declare v_orden wms.tbl_ordenes; r record;
begin
  select * into strict v_orden from wms.tbl_ordenes where id = p_orden_id for update;
  if v_orden.estatus <> 'CONFIRMADA' then
     raise exception 'La orden está en estatus %', v_orden.estatus using errcode = 'WM001';
  end if;

  perform wms.fn_fijar_contexto_movimiento(
    'EMBARQUE', 'ORDEN', p_orden_id, null, p_id_operacion, 'Embarque de orden', p_usuario_id);

  for r in select producto_id, cantidad from wms.rel_orden_producto
            where orden_id = p_orden_id order by producto_id
  loop
     update wms.tbl_inventario
        set cantidad_fisica      = cantidad_fisica    - r.cantidad,
            cantidad_reservada   = cantidad_reservada - r.cantidad,
            version_concurrencia = version_concurrencia + 1,
            actualizado_en       = now()
      where producto_id = r.producto_id and almacen_id = v_orden.almacen_id
        and cantidad_reservada >= r.cantidad;
     -- Sin esta guardia el embarque sería un no-op silencioso: la orden
     -- quedaría ENVIADA (terminal), sin movimiento y con la reserva viva.
     if not found then
        raise exception 'No hay reserva vigente del producto % en el almacén %',
          r.producto_id, v_orden.almacen_id using errcode = 'WM005';
     end if;
  end loop;

  update wms.tbl_ordenes
     set estatus = 'ENVIADA', enviado_en = now(),
         enviado_por_usuario_id = p_usuario_id
   where id = p_orden_id returning * into v_orden;

  perform wms.fn_limpiar_contexto_movimiento();
  return v_orden;
end $$;

create or replace function wms.fn_cancelar_orden(
  p_orden_id bigint, p_motivo text, p_usuario_id bigint, p_id_operacion text)
returns wms.tbl_ordenes language plpgsql as $$
declare v_orden wms.tbl_ordenes; r record;
begin
  select * into strict v_orden from wms.tbl_ordenes where id = p_orden_id for update;
  if v_orden.estatus not in ('BORRADOR','CONFIRMADA') then
     raise exception 'La orden está en estatus % y no puede cancelarse', v_orden.estatus
       using errcode = 'WM001';
  end if;

  if v_orden.estatus = 'CONFIRMADA' then
     perform wms.fn_fijar_contexto_movimiento(
       'LIBERACION', 'ORDEN', p_orden_id, null, p_id_operacion, p_motivo, p_usuario_id);
     for r in select producto_id, cantidad from wms.rel_orden_producto
               where orden_id = p_orden_id order by producto_id
     loop
        update wms.tbl_inventario
           set cantidad_reservada   = cantidad_reservada - r.cantidad,
               version_concurrencia = version_concurrencia + 1,
               actualizado_en       = now()
         where producto_id = r.producto_id and almacen_id = v_orden.almacen_id
           and cantidad_reservada >= r.cantidad;
        if not found then
           raise exception 'No hay reserva vigente del producto % en el almacén %',
             r.producto_id, v_orden.almacen_id using errcode = 'WM005';
        end if;
     end loop;
  else
     -- Una orden en BORRADOR no reservó nada, pero el usuario que cancela
     -- debe quedar registrado igual y validado: fijar el GUC directamente
     -- evadiría la verificación WM014.
     perform wms.fn_fijar_contexto_movimiento(
       'LIBERACION', 'ORDEN', p_orden_id, null, p_id_operacion, p_motivo, p_usuario_id);
  end if;

  update wms.tbl_ordenes
     set estatus = 'CANCELADA', cancelado_en = now(), motivo_cancelacion = p_motivo,
         cancelado_por_usuario_id = p_usuario_id
   where id = p_orden_id returning * into v_orden;

  perform wms.fn_limpiar_contexto_movimiento();
  return v_orden;
end $$;

-- =====================================================================
--  MODELO DE LECTURA
-- =====================================================================

create view wms.vw_tablero_inventario as
select i.producto_id, i.almacen_id,
       p.sku               as producto_sku,
       p.nombre            as producto_nombre,
       p.precio_unitario   as producto_precio,
       p.estatus           as producto_estatus,
       c.codigo            as categoria_codigo,
       c.nombre            as categoria_nombre,
       a.codigo            as almacen_codigo,
       a.nombre            as almacen_nombre,
       p.sku || '@' || a.codigo as localizador,
       i.cantidad_fisica, i.cantidad_reservada, i.cantidad_disponible, i.cantidad_minima,
       (i.cantidad_fisica <= i.cantidad_minima) as es_existencia_baja,
       i.version_concurrencia, i.actualizado_en
  from wms.tbl_inventario i
  join wms.cat_productos  p on p.id = i.producto_id
  join wms.cat_categorias c on c.id = p.categoria_id
  join wms.cat_almacenes  a on a.id = i.almacen_id;

create view wms.vw_ordenes_detalle as
select o.id, o.folio, o.estatus, o.monto_total,
       cl.codigo as cliente_codigo, cl.nombre as cliente_nombre, cl.es_activo as cliente_vigente,
       a.codigo  as almacen_codigo, a.nombre  as almacen_nombre,
       (select count(*) from wms.rel_orden_producto r where r.orden_id = o.id) as partidas,
       (select coalesce(sum(r.cantidad), 0) from wms.rel_orden_producto r
         where r.orden_id = o.id)                                              as unidades,
       o.confirmado_en, o.enviado_en, o.cancelado_en, o.motivo_cancelacion,
       o.notas, u.codigo as creado_por_codigo, u.nombre as creado_por_nombre,
       o.version_concurrencia, o.creado_en
  from wms.tbl_ordenes o
  join wms.cat_clientes  cl on cl.id = o.cliente_id
  join wms.cat_almacenes a  on a.id  = o.almacen_id
  join wms.cat_usuarios  u  on u.id  = o.creado_por_usuario_id;

create view wms.vw_orden_partidas as
select r.id, r.orden_id, r.producto_id,
       p.sku as producto_sku, r.nombre_historico as producto_nombre,
       r.cantidad, r.precio_unitario_historico, r.importe_linea,
       p.precio_unitario as producto_precio_vigente,
       p.sku || '@' || a.codigo as localizador
  from wms.rel_orden_producto r
  join wms.tbl_ordenes   o on o.id = r.orden_id
  join wms.cat_productos p on p.id = r.producto_id
  join wms.cat_almacenes a on a.id = o.almacen_id;

-- Bitácora enriquecida. `estado` se DERIVA en vez de almacenarse: guardar un
-- estado mutable en un libro de solo inserción destruiría la garantía que lo
-- hace confiable. La información es la misma y no admite manipulación.
create view wms.vw_movimientos_detalle as
select m.id, m.uuid_movimiento, m.creado_en, m.tipo_movimiento, m.tipo_origen,
       p.sku    as producto_sku, p.nombre as producto_nombre, p.estatus as producto_estatus,
       a.codigo as almacen_codigo, a.es_activo as almacen_vigente,
       m.delta_fisica, m.fisica_antes, m.fisica_despues,
       m.delta_reservada, m.reservada_antes, m.reservada_despues,
       case
         when m.tipo_movimiento = 'RESERVA' and o.estatus = 'CANCELADA' then 'COMPENSADO'
         when m.tipo_movimiento = 'RESERVA' and o.estatus = 'ENVIADA'   then 'CONSUMIDO'
         else 'APLICADO'
       end as estado,
       o.folio  as orden_folio, o.estatus as orden_estatus, cl.nombre as cliente_nombre,
       m.lote_importacion_id, l.nombre_archivo as lote_archivo,
       m.id_operacion, m.motivo,
       u.id as usuario_id, u.codigo as usuario_codigo, u.nombre as usuario_nombre,
       u.es_activo as usuario_vigente
  from wms.tbl_movimientos_inventario m
  join wms.cat_productos p  on p.id  = m.producto_id
  join wms.cat_almacenes a  on a.id  = m.almacen_id
  join wms.cat_usuarios  u  on u.id  = m.usuario_id
  left join wms.tbl_ordenes           o  on o.id  = m.orden_id
  left join wms.cat_clientes          cl on cl.id = o.cliente_id
  left join wms.tbl_lotes_importacion l  on l.id  = m.lote_importacion_id;

create view wms.vw_importacion_resultado as
select r.lote_id, l.nombre_archivo, l.tipo_lote, l.modo, l.estatus as estatus_lote,
       r.estatus, r.accion, r.codigo_error,
       r.almacen_id, a.codigo as almacen_codigo,
       count(*)                                as renglones,
       coalesce(sum(r.cantidad_aplicada), 0)   as unidades
  from wms.tbl_renglones_importacion r
  join wms.tbl_lotes_importacion     l on l.id = r.lote_id
  left join wms.cat_almacenes        a on a.id = r.almacen_id
 group by r.lote_id, l.nombre_archivo, l.tipo_lote, l.modo, l.estatus,
          r.estatus, r.accion, r.codigo_error, r.almacen_id, a.codigo;

create view wms.vw_indicadores_operacion as
select (select count(*) from wms.cat_productos where estatus = 'ACTIVO')     as productos_activos,
       (select count(*) from wms.cat_almacenes where es_activo)              as almacenes_activos,
       (select coalesce(sum(cantidad_fisica), 0)    from wms.tbl_inventario) as unidades_fisicas,
       (select coalesce(sum(cantidad_reservada), 0) from wms.tbl_inventario) as unidades_reservadas,
       (select count(*) from wms.tbl_inventario
         where cantidad_fisica <= cantidad_minima)                           as productos_existencia_baja,
       (select coalesce(sum(i.cantidad_fisica * p.precio_unitario), 0)
          from wms.tbl_inventario i
          join wms.cat_productos  p on p.id = i.producto_id)                 as valor_inventario,
       (select count(*) from wms.tbl_ordenes where estatus = 'BORRADOR')     as ordenes_borrador,
       (select count(*) from wms.tbl_ordenes where estatus = 'CONFIRMADA')   as ordenes_confirmadas,
       (select count(*) from wms.tbl_ordenes where estatus = 'ENVIADA')      as ordenes_enviadas,
       (select count(*) from wms.tbl_ordenes where estatus = 'CANCELADA')    as ordenes_canceladas,
       (select coalesce(sum(monto_total), 0) from wms.tbl_ordenes
         where estatus in ('CONFIRMADA','ENVIADA'))                          as valor_comprometido;

create view wms.vw_indicadores_almacen as
select a.id as almacen_id, a.codigo as almacen_codigo, a.nombre as almacen_nombre,
       count(i.producto_id)                                              as productos_distintos,
       coalesce(sum(i.cantidad_fisica), 0)                               as unidades_fisicas,
       coalesce(sum(i.cantidad_reservada), 0)                            as unidades_reservadas,
       coalesce(sum(i.cantidad_fisica * p.precio_unitario), 0)           as valor_inventario,
       count(*) filter (where i.cantidad_fisica <= i.cantidad_minima)    as productos_existencia_baja
  from wms.cat_almacenes a
  left join wms.tbl_inventario i on i.almacen_id = a.id
  left join wms.cat_productos  p on p.id = i.producto_id
 group by a.id, a.codigo, a.nombre;

create view wms.vw_serie_movimientos_diaria as
select date_trunc('day', creado_en)::date as dia,
       tipo_movimiento,
       count(*)             as eventos,
       sum(delta_fisica)    as delta_neto_fisico,
       sum(delta_reservada) as delta_neto_reservado
  from wms.tbl_movimientos_inventario
 group by 1, 2;

-- Aportación por usuario sobre un mismo producto: la evidencia de que los
-- movimientos concurrentes se conservan individualmente y suman.
create view wms.vw_aportacion_por_usuario as
select m.producto_id, p.sku as producto_sku, m.almacen_id, a.codigo as almacen_codigo,
       m.usuario_id, u.codigo as usuario_codigo, u.nombre as usuario_nombre,
       count(*)                     as movimientos,
       sum(m.delta_fisica)          as delta_fisico_total,
       min(m.creado_en)             as primer_movimiento_en,
       max(m.creado_en)             as ultimo_movimiento_en
  from wms.tbl_movimientos_inventario m
  join wms.cat_productos p on p.id = m.producto_id
  join wms.cat_almacenes a on a.id = m.almacen_id
  join wms.cat_usuarios  u on u.id = m.usuario_id
 group by m.producto_id, p.sku, m.almacen_id, a.codigo, m.usuario_id, u.codigo, u.nombre;
