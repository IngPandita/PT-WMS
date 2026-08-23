-- =====================================================================
--  Mini WMS + Órdenes  ·  Datos iniciales
-- ---------------------------------------------------------------------
--  Suficientes para demostrar los flujos completos sin capturar nada:
--    5 operadores (uno inactivo, para probar que la traza sobrevive)
--    6 categorías · 3 almacenes · 40 productos · 8 clientes
--    inventario en los 3 almacenes
--    ~200 movimientos con fechas escalonadas en 30 días
--    10 órdenes: 3 BORRADOR · 3 CONFIRMADA · 3 ENVIADA · 1 CANCELADA
--
--  NOTA IMPORTANTE sobre las fechas: la bitácora no admite INSERT directo
--  (0003_permisos.sql), así que los movimientos históricos se generan
--  conduciendo fn_ajustar_existencia y desplazando temporalmente el DEFAULT
--  de creado_en. Es la única vía que respeta el invariante
--  "sum(delta_fisica) = cantidad_fisica" mientras produce una serie temporal
--  real para el dashboard.
-- =====================================================================

set client_min_messages = warning;

-- ---------------------------------------------------------------------
--  Operadores
-- ---------------------------------------------------------------------
-- Desde 0006 el alta en catalogos exige al operador SISTEMA (id 1). El
-- contexto se fija ANTES del primer insert: la excepcion de arranque del
-- trigger solo cubre la tabla vacia, y en un INSERT de varias filas la
-- segunda ya ve la tabla poblada.
select set_config('wms.ctx_usuario_id','1',false);

insert into wms.cat_usuarios (nombre, rol, correo) values
  ('Sistema',           'SISTEMA',    null),
  ('Ana Martínez',      'SUPERVISOR', 'ana@ejemplo.mx'),
  ('Bruno Ortega',      'OPERADOR',   'bruno@ejemplo.mx'),
  ('Carla Ruiz',        'OPERADOR',   'carla@ejemplo.mx'),
  ('Diego Fuentes',     'OPERADOR',   'diego@ejemplo.mx');

-- ---------------------------------------------------------------------
--  Catálogos
-- ---------------------------------------------------------------------
insert into wms.cat_reglas_sku (nombre, es_activo) values ('DEFAULT_V1', true);

insert into wms.cat_categorias (codigo, nombre, descripcion) values
  ('ELEC','Electronica','Cables, adaptadores y periféricos'),
  ('HOGA','Hogar','Artículos para el hogar'),
  ('OFIC','Oficina','Papelería y mobiliario'),
  ('HERR','Herramientas','Herramienta manual y eléctrica'),
  ('DEPO','Deportes','Artículos deportivos'),
  ('ALIM','Alimentos','Abarrotes no perecederos');

insert into wms.cat_almacenes (codigo, nombre, direccion) values
  ('ALM-NTE','Centro de distribución Norte','Av. Industrial 1200, Monterrey'),
  ('ALM-SUR','Centro de distribución Sur','Calz. del Sur 45, Puebla'),
  ('ALM-CTR','Bodega Centro','Eje Central 890, CDMX');

insert into wms.cat_clientes (nombre, correo, telefono) values
  ('Comercializadora del Bajío',   'compras@bajio.mx',      '4771234567'),
  ('Distribuidora Peninsular',     'ops@peninsular.mx',     '9991234567'),
  ('Grupo Ferretero del Norte',    'pedidos@gfn.mx',        '8181234567'),
  ('Abarrotes La Esperanza',       'contacto@esperanza.mx', '5512345678'),
  ('Oficinas Integrales SA',       'admin@ofint.mx',        '3331234567'),
  ('Deportes Titán',               'ventas@titan.mx',       '6641234567'),
  ('Hogar y Estilo',               'hola@hogarestilo.mx',   '2221234567'),
  ('Refacciones González',         'jgonzalez@refa.mx',     '4491234567');

-- ---------------------------------------------------------------------
--  40 productos repartidos en las 6 categorías (SKU acuñado por el motor)
-- ---------------------------------------------------------------------
do $$
declare
  v_nombres text[] := array[
    'Cable HDMI 2 m','Adaptador USB-C','Hub USB 4 puertos','Cargador 65 W','Mouse inalámbrico',
    'Teclado mecánico','Extensión eléctrica','Multicontacto 6 tomas',
    'Juego de sartenes','Set de toallas','Organizador modular','Lámpara de escritorio',
    'Cortina blackout','Tapete antiderrapante','Bote hermético 3 L',
    'Resma papel carta','Engrapadora metálica','Silla ergonómica','Archivero 3 gavetas',
    'Pizarrón blanco 90 cm','Caja de bolígrafos','Cinta adhesiva industrial',
    'Taladro percutor','Juego de desarmadores','Llave ajustable 10"','Martillo de uña',
    'Cinta métrica 8 m','Nivel de burbuja','Caja de herramientas',
    'Balón de fútbol','Mancuernas 5 kg','Tapete de yoga','Cuerda para saltar',
    'Botella térmica 1 L','Bicicleta fija',
    'Arroz 1 kg','Frijol 1 kg','Aceite 1 L','Atún en agua','Café molido 500 g'];
  v_cat bigint; i int;
begin
  for i in 1 .. array_length(v_nombres, 1) loop
     select id into v_cat from wms.cat_categorias
      order by id offset ((i - 1) / 7) % 6 limit 1;
     insert into wms.cat_productos (categoria_id, nombre, descripcion, precio_unitario)
     values (v_cat, v_nombres[i], 'Producto de catálogo inicial',
             round((random() * 900 + 50)::numeric, 2));
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  Inventario y bitácora histórica (30 días escalonados)
-- ---------------------------------------------------------------------
do $$
declare
  v_dia int; v_prod bigint; v_alm bigint; v_usr bigint;
  v_delta int; v_op text; v_n int := 0;
begin
  for v_dia in reverse 30 .. 0 loop
     -- Se desplaza el DEFAULT para que la serie temporal del dashboard sea
     -- real. La bitácora sigue escribiéndose solo por el trigger.
     execute format(
       'alter table wms.tbl_movimientos_inventario alter column creado_en set default (now() - interval ''%s days'')',
       v_dia);

     for v_prod in select id from wms.cat_productos order by random() limit 7 loop
        select id into v_alm from wms.cat_almacenes order by random() limit 1;
        select id into v_usr from wms.cat_usuarios where rol <> 'SISTEMA' order by random() limit 1;

        -- Los primeros días son entradas; después se mezclan salidas.
        if v_dia > 20 then v_delta := (random() * 60 + 40)::int;
        else                v_delta := case when random() < 0.65
                                            then  (random() * 25 + 5)::int
                                            else -(random() * 15 + 1)::int end;
        end if;

        v_n := v_n + 1;
        v_op := v_usr::text || ':semilla-d' || lpad(v_dia::text, 2, '0')
                            || '-n' || lpad(v_n::text, 4, '0');
        begin
           perform wms.fn_ajustar_existencia(
             v_prod, v_alm, v_delta,
             case when v_delta > 0 then 'ENTRADA' else 'SALIDA' end,
             v_usr, v_op, 'SEMILLA');
        exception when sqlstate 'WM002' then
           null;   -- salida que dejaría existencia negativa: se omite
        end;
     end loop;
  end loop;

  alter table wms.tbl_movimientos_inventario alter column creado_en set default now();
end $$;

-- Umbrales de reposición. Un tercio del inventario recibe un mínimo normal;
-- además se dejan ~8 filas POR DEBAJO de su umbral, para que el indicador de
-- reposición del dashboard y el índice parcial ix_..__existencia_baja tengan
-- datos reales que mostrar en lugar de un cero permanente.
update wms.tbl_inventario set cantidad_minima = greatest(5, (cantidad_fisica * 0.15)::int)
 where (producto_id + almacen_id) % 3 = 0;

update wms.tbl_inventario set cantidad_minima = cantidad_fisica + 10
 where (producto_id, almacen_id) in (
   select producto_id, almacen_id from wms.tbl_inventario
    where cantidad_fisica > 0 order by producto_id, almacen_id limit 8);

-- ---------------------------------------------------------------------
--  Órdenes: 3 BORRADOR · 3 CONFIRMADA · 3 ENVIADA · 1 CANCELADA
-- ---------------------------------------------------------------------
do $$
declare
  v_i int; v_orden bigint; v_cli bigint; v_alm bigint; v_usr bigint;
  v_prod bigint; v_cant int; v_disp int; v_partidas int;
begin
  for v_i in 1 .. 10 loop
     select id into v_cli from wms.cat_clientes order by random() limit 1;
     select id into v_alm from wms.cat_almacenes order by random() limit 1;
     select id into v_usr from wms.cat_usuarios where rol <> 'SISTEMA' order by random() limit 1;

     insert into wms.tbl_ordenes (cliente_id, almacen_id, id_operacion, creado_por_usuario_id, notas)
     values (v_cli, v_alm,
             v_usr::text || ':semilla-orden-' || lpad(v_i::text, 4, '0'),
             v_usr, 'Orden de datos iniciales')
     returning id into v_orden;

     -- 1 a 3 partidas, siempre dentro de lo disponible en ese almacén.
     v_partidas := 0;
     for v_prod, v_disp in
        select i.producto_id, i.cantidad_disponible
          from wms.tbl_inventario i
         where i.almacen_id = v_alm and i.cantidad_disponible >= 4
         order by random() limit 3
     loop
        v_cant := least(greatest((v_disp * 0.1)::int, 1), 8);
        insert into wms.rel_orden_producto
          (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico)
        values (v_orden, v_prod, v_cant, '', null);
        v_partidas := v_partidas + 1;
     end loop;

     if v_partidas = 0 then continue; end if;

     -- 1..3 quedan en BORRADOR; 4..6 confirmadas; 7..9 enviadas; 10 cancelada.
     if v_i between 4 and 9 then
        perform wms.fn_confirmar_orden(v_orden, v_usr,
                v_usr::text || ':semilla-conf-' || lpad(v_i::text, 4, '0'));
     end if;
     if v_i between 7 and 9 then
        perform wms.fn_enviar_orden(v_orden, v_usr,
                v_usr::text || ':semilla-envio-' || lpad(v_i::text, 4, '0'));
     end if;
     if v_i = 10 then
        perform wms.fn_cancelar_orden(v_orden, 'Cliente canceló el pedido', v_usr,
                v_usr::text || ':semilla-canc-' || lpad(v_i::text, 4, '0'));
     end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  Baja lógica auditada: un operador inactivo cuyo historial debe seguir
--  siendo resoluble desde cada movimiento suyo.
-- ---------------------------------------------------------------------
update wms.cat_usuarios set es_activo = false
 where nombre = 'Diego Fuentes';

-- ---------------------------------------------------------------------
--  Verificación de la semilla
-- ---------------------------------------------------------------------
do $$
declare v_desc int;
begin
  select count(*) into v_desc
    from wms.tbl_inventario i
   where i.cantidad_fisica <> coalesce(
         (select sum(m.delta_fisica) from wms.tbl_movimientos_inventario m
           where m.producto_id = i.producto_id and m.almacen_id = i.almacen_id), 0);
  if v_desc > 0 then
     raise exception 'La semilla dejó % filas de inventario descuadradas contra la bitácora', v_desc;
  end if;
end $$;

select 'usuarios'    as entidad, count(*) from wms.cat_usuarios
union all select 'categorias',   count(*) from wms.cat_categorias
union all select 'almacenes',    count(*) from wms.cat_almacenes
union all select 'clientes',     count(*) from wms.cat_clientes
union all select 'productos',    count(*) from wms.cat_productos
union all select 'inventario',   count(*) from wms.tbl_inventario
union all select 'movimientos',  count(*) from wms.tbl_movimientos_inventario
union all select 'ordenes',      count(*) from wms.tbl_ordenes
union all select 'partidas',     count(*) from wms.rel_orden_producto
union all select 'dias de serie',count(*) from wms.vw_serie_movimientos_diaria;
