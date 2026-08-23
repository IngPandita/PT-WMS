-- =====================================================================
--  Mini WMS + Órdenes  ·  0006 · El alta en catálogos es del usuario 1
-- ---------------------------------------------------------------------
--  La restricción vive en el MOTOR, no en la API ni en el botón. Tres
--  razones concretas:
--
--    1. Ocultar el botón no es una autorización: cualquiera puede llamar
--       al endpoint directo.
--    2. Validar solo en la API dejaría abierta toda ruta que cree un
--       catálogo de paso. Ya existe una: la IMPORTACIÓN crea productos.
--    3. Un catálogo nuevo que se agregue después heredaría el hueco. Aquí
--       basta con añadirle el trigger, y el DO al final de este archivo lo
--       aplica a todas las tablas cat_ que existan.
--
--  VÍA DE ESCAPE ENCONTRADA Y CERRADA
--    ManejadorImportar hace `insert into wms.cat_productos` para dar de
--    alta productos nuevos. Con este trigger, un operador que no sea
--    SISTEMA ya no puede crear productos por esa vía. Su importación NO
--    falla entera: cada renglón corre bajo su propio SAVEPOINT, así que
--    los renglones que solo ACTUALIZAN inventario de productos existentes
--    siguen aplicándose y los que requerirían un alta se marcan con
--    codigo_error = 'PERMISO_ALTA_CATALOGO'.
--
--  ALCANCE DELIBERADO: solo el ALTA.
--    La edición y la desactivación conservan su política actual, que es
--    distinta: fn_sellar_baja_logica exige un usuario identificado, pero
--    NO exige que sea el 1. Es una inconsistencia real —dar de alta está
--    más restringido que dar de baja— y se documenta en la especificación
--    en lugar de cambiarla por cuenta propia.
-- =====================================================================

create or replace function wms.fn_exigir_sistema_para_alta_catalogo()
returns trigger language plpgsql as $$
declare v_usuario bigint; v_hay_usuarios boolean;
begin
  -- Excepción de arranque: mientras no exista NINGÚN operador el sistema no
  -- está inicializado y nadie podría autorizarse a sí mismo. Se permite
  -- únicamente para poder sembrar el primer usuario.
  select exists (select 1 from wms.cat_usuarios) into v_hay_usuarios;
  if not v_hay_usuarios then return new; end if;

  v_usuario := nullif(current_setting('wms.ctx_usuario_id', true), '')::bigint;

  if v_usuario is null then
     raise exception 'Dar de alta en un catálogo exige declarar el operador responsable'
       using errcode = 'WM014';
  end if;

  if v_usuario <> 1 then
     raise exception 'Solo el usuario SISTEMA puede dar de alta registros en catálogos (intentó el usuario %)',
       v_usuario using errcode = 'WM020';
  end if;

  return new;
end $$;

comment on function wms.fn_exigir_sistema_para_alta_catalogo is
  'Alta en catálogos restringida al usuario 1 (SISTEMA). Vive en el motor para que ninguna ruta —incluida la importación, que crea productos— pueda saltarla.';

-- Se aplica a TODAS las tablas cat_ que existan hoy. El nombre del trigger
-- empieza con 'a_' para que dispare antes que cualquier otro BEFORE INSERT
-- de la tabla (Postgres los ordena alfabéticamente): si el alta no está
-- autorizada, no tiene sentido acuñar un SKU ni sellar una baja.
do $$
declare r record;
begin
  for r in
    select c.relname as tabla
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'wms' and c.relkind = 'r' and c.relname like 'cat\_%'
     order by c.relname
  loop
    execute format(
      'drop trigger if exists a_trg_%1$s__alta_solo_sistema on wms.%1$I', r.tabla);
    execute format(
      'create trigger a_trg_%1$s__alta_solo_sistema before insert on wms.%1$I
         for each row execute function wms.fn_exigir_sistema_para_alta_catalogo()', r.tabla);
    raise notice 'alta restringida en wms.%', r.tabla;
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  Comprobación de cobertura
-- ---------------------------------------------------------------------
-- Falla la migración si quedara alguna tabla cat_ sin la restricción. Es la
-- red que hace que un catálogo nuevo no herede el hueco en silencio.
do $$
declare v_faltantes text;
begin
  select string_agg(c.relname, ', ') into v_faltantes
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'wms' and c.relkind = 'r' and c.relname like 'cat\_%'
     and not exists (
       select 1 from pg_trigger t
        where t.tgrelid = c.oid and not t.tgisinternal
          and t.tgname = 'a_trg_' || c.relname || '__alta_solo_sistema');

  if v_faltantes is not null then
     raise exception 'Estas tablas de catálogo quedaron sin restricción de alta: %', v_faltantes;
  end if;
end $$;

-- ---------------------------------------------------------------------
--  Índices para la paginación
-- ---------------------------------------------------------------------
-- La paginación con "página X de N" necesita el conteo total, que se obtiene
-- con count(*) over() en la misma consulta. El orden estable evita que un
-- registro salte de página entre peticiones.
create index if not exists ix_tbl_ordenes__fecha_id
  on wms.tbl_ordenes (creado_en desc, id desc);
