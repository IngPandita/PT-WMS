#!/usr/bin/env bash
# =====================================================================
#  Pruebas de concurrencia REAL: sesiones psql simultáneas contra la
#  misma fila de inventario. Es lo único que no puede demostrarse desde
#  un solo script SQL secuencial.
# =====================================================================
set -uo pipefail
CT=${CT:-wms-conc}
N=${N:-25}
export MSYS_NO_PATHCONV=1
fallos=0

q() { docker exec -i "$CT" psql -U postgres -d wms -qtAX -c "$1" 2>&1; }
afirmar() { # afirmar <descripcion> <obtenido> <esperado>
  if [ "$2" = "$3" ]; then echo "PASA  $1 (= $3)"
  else echo "FALLO $1: obtenido=$2 esperado=$3"; fallos=$((fallos+1)); fi
}

docker rm -f "$CT" >/dev/null 2>&1 || true
docker run -d --name "$CT" -e POSTGRES_PASSWORD=v -e POSTGRES_DB=wms postgres:16-alpine >/dev/null
# La imagen oficial levanta un servidor TEMPORAL durante initdb y lo apaga
# antes de arrancar el definitivo. Ese temporal escucha SOLO en el socket
# unix, asi que preguntar por TCP distingue uno de otro: sondear el socket
# devuelve "listo" en plena ventana de init y la migracion se estrella.
docker exec "$CT" sh -c 'for i in $(seq 1 90); do pg_isready -h 127.0.0.1 -U postgres -q && exit 0; sleep 1; done; exit 1' \
  || { echo "El PostgreSQL desechable no arranco"; docker rm -f "$CT" >/dev/null; exit 1; }
for f in db/migraciones/*.sql; do
  docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 --single-transaction -q < "$f" >/dev/null 2>&1 \
    || { echo "FALLO migracion $f"; exit 1; }
done

q "select set_config('wms.ctx_usuario_id','1',false);
   insert into wms.cat_usuarios (nombre,rol) values ('Sistema','SISTEMA');
   insert into wms.cat_categorias (codigo,nombre) values ('ELEC','Electronica');
   insert into wms.cat_almacenes (codigo,nombre) values ('ALM-NTE','Norte');
   insert into wms.cat_clientes (nombre) values ('Cliente');
   insert into wms.cat_productos (categoria_id,nombre,precio_unitario)
     select id,'Cable',100 from wms.cat_categorias;
   insert into wms.cat_productos (categoria_id,nombre,precio_unitario)
     select id,'Teclado',200 from wms.cat_categorias;" >/dev/null
for i in $(seq 2 $((N+4))); do q "select set_config('wms.ctx_usuario_id','1',false); insert into wms.cat_usuarios (nombre) values ('Operador $i');" >/dev/null; done
q "select cantidad_fisica from wms.fn_ajustar_existencia(1,1,1000,'ENTRADA',1,'1:SEED-CONC-0001','SEMILLA');" >/dev/null
q "select cantidad_fisica from wms.fn_ajustar_existencia(2,1,1000,'ENTRADA',1,'1:SEED-CONC-0002','SEMILLA');" >/dev/null

echo
echo "=== 1) $N operadores distintos, $N operaciones distintas, MISMO producto ==="
base=$(q "select cantidad_fisica from wms.tbl_inventario where producto_id=1;")
for i in $(seq 1 $N); do
  u=$((i+1))
  q "select wms.fn_ajustar_existencia(1,1,1,'AJUSTE',$u,'$u:CONC-DISTINTA-$(printf '%04d' $i)');" >/dev/null &
done
wait
fin=$(q "select cantidad_fisica from wms.tbl_inventario where producto_id=1;")
mov=$(q "select count(*) from wms.tbl_movimientos_inventario where id_operacion like '%CONC-DISTINTA-%';")
afirmar "existencia tras $N ajustes concurrentes" "$fin" "$((base+N))"
afirmar "movimientos registrados (uno por operador)" "$mov" "$N"

echo
echo "=== 2) $N envios SIMULTANEOS del MISMO id_operacion ==="
base2=$(q "select cantidad_fisica from wms.tbl_inventario where producto_id=1;")
for _ in $(seq 1 $N); do
  q "select wms.fn_ajustar_existencia(1,1,7,'AJUSTE',2,'2:CONC-MISMA-0001');" >/dev/null &
done
wait
fin2=$(q "select cantidad_fisica from wms.tbl_inventario where producto_id=1;")
mov2=$(q "select count(*) from wms.tbl_movimientos_inventario where id_operacion='2:CONC-MISMA-0001';")
afirmar "existencia tras $N reenvios de la MISMA operacion" "$fin2" "$((base2+7))"
afirmar "movimientos de esa operacion" "$mov2" "1"

echo
echo "=== 3) reserva de operacion: $N sesiones compiten por el mismo id ==="
# El veredicto se registra DENTRO de la base: escribir desde N procesos al
# mismo archivo del host no es atómico y falsearía la medición.
q "create table if not exists public.veredictos (v text);" >/dev/null
for _ in $(seq 1 $N); do
  q "insert into public.veredictos select veredicto from wms.fn_reservar_operacion('2:CONC-RESERVA-0001','a','/r','h',2);" >/dev/null &
done
wait
total=$(q "select count(*) from public.veredictos;")
nuevas=$(q "select count(*) from public.veredictos where v='NUEVA';")
encurso=$(q "select count(*) from public.veredictos where v='EN_CURSO';")
filas=$(q "select count(*) from wms.tbl_operaciones where id_operacion='2:CONC-RESERVA-0001';")
intentos=$(q "select intentos from wms.tbl_operaciones where id_operacion='2:CONC-RESERVA-0001';")
afirmar "las $N sesiones obtuvieron veredicto" "$total" "$N"
afirmar "exactamente una reserva gana" "$nuevas" "1"
afirmar "las demas reciben EN_CURSO" "$encurso" "$((N-1))"
afirmar "una sola fila de operacion" "$filas" "1"
afirmar "intentos contabilizados" "$intentos" "$N"

echo
echo "=== 4) ordenes concurrentes con los mismos productos: sin deadlock ==="
q "insert into wms.tbl_ordenes (cliente_id,almacen_id,id_operacion,creado_por_usuario_id) values (1,1,'2:ORD-CONC-A001',2);
   insert into wms.tbl_ordenes (cliente_id,almacen_id,id_operacion,creado_por_usuario_id) values (1,1,'3:ORD-CONC-B001',3);" >/dev/null
oa=$(q "select id from wms.tbl_ordenes where id_operacion='2:ORD-CONC-A001';")
ob=$(q "select id from wms.tbl_ordenes where id_operacion='3:ORD-CONC-B001';")
# La orden A inserta A,B; la orden B inserta B,A. El bucle ORDER BY producto_id
# de fn_confirmar_orden debe imponer el mismo orden de locks en ambas.
q "insert into wms.rel_orden_producto (orden_id,producto_id,cantidad,nombre_historico,precio_unitario_historico) values ($oa,1,2,'',null),($oa,2,2,'',null);
   insert into wms.rel_orden_producto (orden_id,producto_id,cantidad,nombre_historico,precio_unitario_historico) values ($ob,2,2,'',null),($ob,1,2,'',null);" >/dev/null
for r in 1 2 3 4 5 6 7 8 9 10; do
  q "select estatus from wms.fn_confirmar_orden($oa,2,'2:ORD-CONC-CONF-A$r');" >/dev/null &
  q "select estatus from wms.fn_confirmar_orden($ob,3,'3:ORD-CONC-CONF-B$r');" >/dev/null &
done
wait
dl=$(q "select deadlocks from pg_stat_database where datname='wms';")
ea=$(q "select estatus from wms.tbl_ordenes where id=$oa;")
eb=$(q "select estatus from wms.tbl_ordenes where id=$ob;")
afirmar "deadlocks detectados por el motor" "$dl" "0"
afirmar "orden A confirmada" "$ea" "CONFIRMADA"
afirmar "orden B confirmada" "$eb" "CONFIRMADA"
ra=$(q "select cantidad_reservada from wms.tbl_inventario where producto_id=1;")
afirmar "reserva del producto 1 (2 por orden, sin duplicados)" "$ra" "4"

echo
echo "=== 5) invariante global: la bitacora reconstruye la existencia ==="
cuadra=$(q "select bool_and(ok) from (
  select i.cantidad_fisica = coalesce((select sum(m.delta_fisica) from wms.tbl_movimientos_inventario m
    where m.producto_id=i.producto_id and m.almacen_id=i.almacen_id),0) as ok
  from wms.tbl_inventario i) t;")
afirmar "sum(delta_fisica) = cantidad_fisica en todo el inventario" "$cuadra" "t"

docker rm -f "$CT" >/dev/null
echo
if [ "$fallos" -eq 0 ]; then echo "=== CONCURRENCIA: TODAS LAS PRUEBAS PASARON ==="; exit 0
else echo "=== CONCURRENCIA: $fallos FALLO(S) ==="; exit 1; fi
