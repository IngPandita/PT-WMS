#!/usr/bin/env bash
# Aplica las migraciones sobre un PostgreSQL desechable y ejecuta las pruebas
# de humo. Es la verificacion I0 de la especificacion: sin esto, el esquema
# solo esta revisado, no probado.
set -euo pipefail
CT=${CT:-wms-verif}
export MSYS_NO_PATHCONV=1

docker rm -f "$CT" >/dev/null 2>&1 || true
docker run -d --name "$CT" -e POSTGRES_PASSWORD=verif -e POSTGRES_DB=wms postgres:16-alpine >/dev/null
# La imagen oficial levanta un servidor TEMPORAL durante initdb y lo apaga
# antes de arrancar el definitivo. Ese temporal escucha SOLO en el socket
# unix, asi que preguntar por TCP distingue uno de otro: sondear el socket
# devuelve "listo" en plena ventana de init y la migracion se estrella.
docker exec "$CT" sh -c 'for i in $(seq 1 90); do pg_isready -h 127.0.0.1 -U postgres -q && exit 0; sleep 1; done; exit 1' \
  || { echo "El PostgreSQL desechable no arranco"; docker rm -f "$CT" >/dev/null; exit 1; }

for f in db/migraciones/*.sql; do
  printf '%-32s ' "$(basename "$f")"
  docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 --single-transaction -q < "$f"
  echo OK
done

echo
echo '########## SUITE 1/5: idempotencia y ajustes de existencia ##########'
docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 -q < db/pruebas/humo_idempotencia.sql

echo
echo '########## SUITE 2/5: ciclo de ordenes, rollback, importacion, soft-delete ##########'
docker exec "$CT" psql -U postgres -d wms -q -c "drop schema wms cascade" >/dev/null
for f in db/migraciones/*.sql; do
  docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 --single-transaction -q < "$f"
done
docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 -q < db/pruebas/humo_ordenes.sql

echo
echo '--- el rol de la aplicacion NO puede falsificar la bitacora ---'
# psql sale != 0 a proposito aqui; con pipefail eso envenenaria el pipeline,
# asi que se captura la salida primero y despues se evalua.
salida=$(docker exec "$CT" psql -U wms_api -d wms -q -c \
  "insert into wms.tbl_movimientos_inventario (producto_id,almacen_id,tipo_movimiento,delta_fisica,fisica_antes,fisica_despues,id_operacion,usuario_id) values (1,1,'ENTRADA',50,0,50,'2:FALSO-0001',2);" \
  2>&1 || true)
case "$salida" in
  *"permission denied"*) echo "PASA  INSERT directo denegado al rol de la aplicacion" ;;
  *) echo "FALLO  la bitacora acepto un INSERT directo: $salida"; docker rm -f "$CT" >/dev/null; exit 1 ;;
esac

echo
echo '########## SUITE 4/5: reversa (desactivacion) de movimientos ##########'
docker exec "$CT" psql -U postgres -d wms -q -c "drop schema wms cascade" >/dev/null
for f in db/migraciones/*.sql; do
  docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 --single-transaction -q < "$f"
done
docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 -q < db/pruebas/humo_reversa.sql


echo
echo '########## SUITE 5/5: edicion y baja logica de catalogos ##########'
docker exec "$CT" psql -U postgres -d wms -q -c "drop schema wms cascade" >/dev/null
for f in db/migraciones/*.sql; do
  docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 --single-transaction -q < "$f"
done
docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 -q < db/pruebas/humo_catalogos.sql
echo
echo '########## SEMILLA: datos iniciales sobre esquema limpio ##########'
docker exec "$CT" psql -U postgres -d wms -q -c "drop schema wms cascade" >/dev/null
for f in db/migraciones/*.sql; do
  docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 --single-transaction -q < "$f"
done
docker exec -i "$CT" psql -U postgres -d wms -v ON_ERROR_STOP=1 -q < db/semilla.sql
bajas=$(docker exec "$CT" psql -U postgres -d wms -qtAX -c \
  "select productos_existencia_baja from wms.vw_indicadores_operacion;")
if [ "$bajas" -gt 0 ]; then echo "PASA  la semilla deja $bajas alertas de reposicion para el dashboard"
else echo "FALLO  el indicador de reposicion quedaria vacio"; docker rm -f "$CT" >/dev/null; exit 1; fi

docker rm -f "$CT" >/dev/null

echo
echo '########## SUITE 3/5: concurrencia real con sesiones paralelas ##########'
bash db/pruebas/concurrencia.sh || { echo "FALLO la suite de concurrencia"; exit 1; }

echo
echo "=== VERIFICACION COMPLETA: 5/5 SUITES ==="
