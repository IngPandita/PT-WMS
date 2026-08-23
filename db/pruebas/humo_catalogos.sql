\set ON_ERROR_STOP on
\pset pager off

-- =====================================================================
--  Edicion y baja logica de catalogos  (migracion 0007)
-- =====================================================================

-- El alta exige al operador SISTEMA (id 1). El contexto se fija ANTES del
-- primer insert: la excepcion de arranque del trigger solo cubre la tabla
-- vacia, y en un INSERT de varias filas la segunda ya ve la tabla poblada.
select set_config('wms.ctx_usuario_id','1',false);

insert into wms.cat_usuarios (nombre, rol) values ('Sistema','SISTEMA');   -- 1
insert into wms.cat_usuarios (nombre) values ('Operador Dos');             -- 2
insert into wms.cat_usuarios (nombre, rol) values ('Supervisora','SUPERVISOR'); -- 3
insert into wms.cat_reglas_sku (nombre, es_activo) values ('DEFAULT_V1', true);
insert into wms.cat_categorias (codigo, nombre) values ('ELEC','Electronica');
insert into wms.cat_categorias (codigo, nombre) values ('ALIM','Alimentos');
insert into wms.cat_almacenes (codigo, nombre) values ('ALM-NTE','Norte');
insert into wms.cat_clientes (nombre) values ('Cliente Uno');

select id as cat_elec from wms.cat_categorias where codigo = 'ELEC' \gset
select id as cat_alim from wms.cat_categorias where codigo = 'ALIM' \gset
select id as alm      from wms.cat_almacenes  \gset
select id as cli      from wms.cat_clientes   \gset

\echo ''
\echo '=== 1) la version de concurrencia existe en los cuatro catalogos ==='
do $$
declare v_faltantes text;
begin
  select string_agg(t, ', ') into v_faltantes from unnest(
    array['cat_usuarios','cat_categorias','cat_almacenes','cat_clientes','cat_productos']) t
   where not exists (select 1 from information_schema.columns
                      where table_schema='wms' and table_name=t
                        and column_name='version_concurrencia');
  if v_faltantes is not null then
     raise exception 'FALLO: sin version_concurrencia: %', v_faltantes;
  end if;
  raise notice 'PASA  los cinco catalogos llevan version_concurrencia';
end $$;

\echo ''
\echo '=== 2) toda edicion incrementa la version ==='
update wms.cat_clientes set nombre = 'Cliente Uno S.A.' where id = :cli;
do $$ begin
  if (select version_concurrencia from wms.cat_clientes where id = (select min(id) from wms.cat_clientes)) = 2
     then raise notice 'PASA  la version paso de 1 a 2';
     else raise exception 'FALLO: la version no se incremento'; end if;
end $$;

\echo ''
\echo '=== 3) el codigo de una categoria SIN productos si se corrige ==='
update wms.cat_categorias set codigo = 'ALIB' where id = :cat_alim;
select codigo as codigo_corregido from wms.cat_categorias where id = :cat_alim;

\echo ''
\echo '=== 4) con un producto acunado, el codigo queda congelado ==='
insert into wms.cat_productos (categoria_id, nombre, precio_unitario)
  values (:cat_elec, 'Cable HDMI', 100);
select id as prod from wms.cat_productos \gset
do $$ begin
  update wms.cat_categorias set codigo = 'ELEX' where codigo = 'ELEC';
  raise exception 'FALLO: se cambio el prefijo de un SKU ya acunado';
exception when foreign_key_violation then
  raise notice 'PASA  el prefijo acunado esta protegido por la FK (23503)';
end $$;

\echo ''
\echo '=== 5) recategorizar NO reescribe el SKU ==='
update wms.cat_productos set categoria_id = :cat_alim where id = :prod;
do $$ begin
  if (select sku from wms.cat_productos limit 1) = 'ELEC-0001'
     then raise notice 'PASA  el SKU sigue siendo ELEC-0001 tras recategorizar';
     else raise exception 'FALLO: el SKU cambio al recategorizar'; end if;
end $$;

\echo ''
\echo '=== 6) el rol solo lo cambia el operador 1 ==='
select set_config('wms.ctx_usuario_id','2',false);
do $$ begin
  update wms.cat_usuarios set rol = 'SUPERVISOR' where id = 2;
  raise exception 'FALLO: un operador se ascendio a si mismo';
exception when sqlstate 'WM021' then
  raise notice 'PASA  ascenso bloqueado en el MOTOR (WM021)';
end $$;

-- Lo demas del mismo registro si se corrige con cualquier operador.
update wms.cat_usuarios set nombre = 'Operador Dos Corregido' where id = 2;
select nombre as nombre_corregido from wms.cat_usuarios where id = 2;

\echo ''
\echo '=== 7) el operador 1 si puede cambiar el rol de otro ==='
select set_config('wms.ctx_usuario_id','1',false);
update wms.cat_usuarios set rol = 'SUPERVISOR' where id = 2;
select rol as rol_nuevo from wms.cat_usuarios where id = 2;

\echo ''
\echo '=== 8) el rol del propio operador SISTEMA es fijo ==='
do $$ begin
  update wms.cat_usuarios set rol = 'OPERADOR' where id = 1;
  raise exception 'FALLO: se degrado al operador SISTEMA';
exception when sqlstate 'WM021' then raise notice 'PASA  el rol del SISTEMA no se toca (WM021)'; end $$;

\echo ''
\echo '=== 9) el operador SISTEMA no se puede desactivar ==='
do $$ begin
  update wms.cat_usuarios set es_activo = false where id = 1;
  raise exception 'FALLO: se desactivo al unico operador que da de alta';
exception when sqlstate 'WM022' then
  raise notice 'PASA  la baja del operador SISTEMA esta bloqueada (WM022)';
end $$;

\echo ''
\echo '=== 10) la baja logica sella quien y cuando ==='
select set_config('wms.ctx_usuario_id','3',false);
update wms.cat_clientes set es_activo = false where id = :cli;
do $$
declare r record;
begin
  select es_activo, desactivado_en, desactivado_por_usuario_id into r
    from wms.cat_clientes where id = (select min(id) from wms.cat_clientes);
  if r.es_activo then raise exception 'FALLO: no se desactivo'; end if;
  if r.desactivado_en is null then raise exception 'FALLO: sin fecha de baja'; end if;
  if r.desactivado_por_usuario_id <> 3 then
     raise exception 'FALLO: el autor de la baja es % y se esperaba 3', r.desactivado_por_usuario_id;
  end if;
  raise notice 'PASA  la baja quedo sellada con fecha y autor (usuario 3)';
end $$;

\echo ''
\echo '=== 11) desactivar sin operador declarado se rechaza ==='
select set_config('wms.ctx_usuario_id','',false);
do $$ begin
  update wms.cat_almacenes set es_activo = false where codigo = 'ALM-NTE';
  raise exception 'FALLO: baja anonima aceptada';
exception when sqlstate 'WM014' then
  raise notice 'PASA  la baja exige operador (WM014)';
end $$;

\echo ''
\echo '=== 12) reactivar conserva el rastro de la baja anterior ==='
select set_config('wms.ctx_usuario_id','2',false);
update wms.cat_clientes set es_activo = true where id = :cli;
do $$
declare r record;
begin
  select es_activo, desactivado_en, desactivado_por_usuario_id into r
    from wms.cat_clientes where id = (select min(id) from wms.cat_clientes);
  if not r.es_activo then raise exception 'FALLO: no se reactivo'; end if;
  if r.desactivado_en is null or r.desactivado_por_usuario_id is null then
     raise exception 'FALLO: reactivar borro el rastro de la baja';
  end if;
  raise notice 'PASA  el sello de la baja anterior sobrevive a la reactivacion';
end $$;

\echo ''
\echo '=== 13) el alta sigue siendo del operador 1, no cambio con 0007 ==='
do $$ begin
  insert into wms.cat_clientes (nombre) values ('Cliente del operador dos');
  raise exception 'FALLO: un operador cualquiera dio de alta un cliente';
exception when sqlstate 'WM020' then
  raise notice 'PASA  el alta sigue reservada al operador SISTEMA (WM020)';
end $$;

\echo ''
\echo '=== 14) un catalogo no se borra si algo lo referencia ==='
select set_config('wms.ctx_usuario_id','1',false);
do $$ begin
  delete from wms.cat_categorias where codigo = 'ELEC';
  raise exception 'FALLO: se borro una categoria con SKU acunado';
exception when foreign_key_violation then
  raise notice 'PASA  el borrado fisico sigue restringido (23503)';
end $$;

\echo ''
\echo '=== CATALOGOS: TODAS LAS PRUEBAS PASARON ==='
