-- =====================================================================
--  Mini WMS + Órdenes  ·  0007 · Edición y baja de catálogos
-- ---------------------------------------------------------------------
--  Hasta aquí un catálogo se podía crear y consultar, pero no corregir.
--  Esta migración habilita la edición y la baja lógica desde la interfaz,
--  y cierra las tres cosas que faltaban para que fueran seguras.
--
--  1. CONCURRENCIA OPTIMISTA EN LOS CUATRO CATÁLOGOS QUE NO LA TENÍAN
--     cat_productos y tbl_ordenes ya llevaban version_concurrencia;
--     usuarios, categorías, almacenes y clientes solo tenían
--     actualizado_en. Sin una versión, dos operadores editando el mismo
--     cliente producen «el último gana» en silencio, que es justo lo que
--     el resto del sistema evita. Se uniforma.
--
--  2. EL ROL DE UN OPERADOR NO LO CAMBIA CUALQUIERA
--     Hallazgo de la revisión: PermisoExportacion autoriza por ROL
--     (SUPERVISOR y SISTEMA). Si la edición de catálogos dejara tocar
--     cat_usuarios.rol libremente, un OPERADOR podría ascenderse a
--     SUPERVISOR y concederse la exportación —que incluye precios y
--     valuación— sin pasar por nadie. Es una escalada de privilegios por
--     la puerta de atrás, así que el rol solo lo cambia el usuario 1.
--
--  3. EL OPERADOR SISTEMA NO SE PUEDE DESACTIVAR
--     El usuario 1 es el único que puede dar de alta en catálogos, y
--     fn_ajustar_existencia rechaza a los operadores inactivos. Darlo de
--     baja dejaría el sistema sin nadie capaz de crear un catálogo, y sin
--     forma de revertirlo desde la propia aplicación. Se bloquea.
--
--  LO QUE NO CAMBIA, Y POR QUÉ
--     Editar y desactivar siguen abiertos a cualquier operador
--     identificado; solo el ALTA exige ser el usuario 1. La asimetría es
--     deliberada y está documentada en la especificación (§3.11): el alta
--     introduce identificadores que otras filas empezarán a referenciar,
--     mientras que la baja es reversible y queda sellada con fecha y
--     autor. Igualarlas es un cambio de política, no una corrección.
-- ---------------------------------------------------------------------
--  SQLSTATE de negocio añadidos desde 0001 (el encabezado de aquel
--  archivo solo llegaba a WM016):
--    WM017 Sin permiso para la acción       WM020 Alta de catálogo ajena
--    WM018 Desactivación de movimiento      WM021 Cambio de rol no autorizado
--    WM019 Movimiento no reversible         WM022 SISTEMA no se desactiva
--                                           WM023 Vigencia sin cambio
-- =====================================================================

-- ---------------------------------------------------------------------
--  1 · Versión de concurrencia en los catálogos que faltaban
-- ---------------------------------------------------------------------
alter table wms.cat_usuarios   add column if not exists version_concurrencia bigint not null default 1;
alter table wms.cat_categorias add column if not exists version_concurrencia bigint not null default 1;
alter table wms.cat_almacenes  add column if not exists version_concurrencia bigint not null default 1;
alter table wms.cat_clientes   add column if not exists version_concurrencia bigint not null default 1;

-- fn_incrementar_version_concurrencia también toca actualizado_en, así que
-- releva por completo a fn_tocar_actualizado_en en estas tablas.
drop trigger if exists trg_cat_usuarios__actualizado   on wms.cat_usuarios;
drop trigger if exists trg_cat_categorias__actualizado on wms.cat_categorias;
drop trigger if exists trg_cat_almacenes__actualizado  on wms.cat_almacenes;
drop trigger if exists trg_cat_clientes__actualizado   on wms.cat_clientes;

create trigger trg_cat_usuarios__actualizado   before update on wms.cat_usuarios
  for each row execute function wms.fn_incrementar_version_concurrencia();
create trigger trg_cat_categorias__actualizado before update on wms.cat_categorias
  for each row execute function wms.fn_incrementar_version_concurrencia();
create trigger trg_cat_almacenes__actualizado  before update on wms.cat_almacenes
  for each row execute function wms.fn_incrementar_version_concurrencia();
create trigger trg_cat_clientes__actualizado   before update on wms.cat_clientes
  for each row execute function wms.fn_incrementar_version_concurrencia();

-- ---------------------------------------------------------------------
--  2 y 3 · Protección del registro de operadores
-- ---------------------------------------------------------------------
create or replace function wms.fn_proteger_operadores()
returns trigger language plpgsql as $$
declare v_actor bigint;
begin
  v_actor := nullif(current_setting('wms.ctx_usuario_id', true), '')::bigint;

  -- El usuario 1 sostiene el alta de catálogos. Desactivarlo dejaría al
  -- sistema sin nadie que pueda crear un catálogo, y sin forma de deshacerlo
  -- desde la aplicación.
  if old.id = 1 and old.es_activo and not new.es_activo then
     raise exception 'El operador SISTEMA no se puede desactivar: es el único autorizado a dar de alta en catálogos'
       using errcode = 'WM022';
  end if;

  if new.rol is distinct from old.rol then
     -- El rol decide quién exporta el catálogo con precios y valuación.
     -- Dejarlo abierto convertiría la edición en una vía de ascenso.
     if v_actor is distinct from 1 then
        raise exception 'Solo el usuario SISTEMA puede cambiar el rol de un operador (intentó el usuario %)',
          coalesce(v_actor::text, 'no declarado') using errcode = 'WM021';
     end if;
     if old.id = 1 then
        raise exception 'El rol del operador SISTEMA es fijo' using errcode = 'WM021';
     end if;
  end if;

  return new;
end $$;

comment on function wms.fn_proteger_operadores is
  'Impide desactivar al operador 1 y reserva el cambio de rol al operador 1. El rol gobierna el permiso de exportación, así que editarlo libremente sería una escalada de privilegios.';

drop trigger if exists a_trg_cat_usuarios__proteger on wms.cat_usuarios;
create trigger a_trg_cat_usuarios__proteger
  before update on wms.cat_usuarios
  for each row execute function wms.fn_proteger_operadores();

-- ---------------------------------------------------------------------
--  4 · Reactivación
-- ---------------------------------------------------------------------
-- Reactivar NO limpia desactivado_en ni desactivado_por_usuario_id: la baja
-- ocurrió y su rastro sobrevive. El CHECK de sello es unidireccional
-- justamente para permitirlo, y ya está probado (I38). No hace falta nada
-- nuevo aquí; se deja escrito para que quien lea la migración no busque el
-- código que «falta».
