#!/usr/bin/env bash
# =====================================================================
#  Verificación EXTREMO A EXTREMO sobre HTTP.
#
#  Es la única forma de cerrar los escenarios que la suite SQL no puede
#  cubrir: reintento tras timeout, latencia real y cancelación del cliente
#  a mitad de transacción. Levanta Postgres + migraciones + semilla + la
#  API en .NET 8 y ejerce los endpoints con curl.
# =====================================================================
set -uo pipefail
export MSYS_NO_PATHCONV=1
RED=wms-red; PG=wms-e2e-db; API=wms-e2e-api; PUERTO=${PUERTO:-8099}
BASE="http://localhost:$PUERTO"
fallos=0

limpiar() { docker rm -f "$API" "$PG" >/dev/null 2>&1 || true; docker network rm "$RED" >/dev/null 2>&1 || true; rm -rf .tmp-verificacion; }
trap limpiar EXIT

afirmar() { if [ "$2" = "$3" ]; then echo "PASA  $1 (= $3)"; else echo "FALLO $1: obtenido=[$2] esperado=[$3]"; fallos=$((fallos+1)); fi; }
# Primera coincidencia: los campos de nivel superior van antes del arreglo
# 'detalle', cuyos elementos repiten nombres como 'estatus'.
campo() { echo "$1" | grep -o "\"$2\":[^,}]*" | head -1 | cut -d: -f2- | tr -d '" '; }

limpiar
docker network create "$RED" >/dev/null

echo '--- Postgres + migraciones + semilla ---'
docker run -d --name "$PG" --network "$RED" -e POSTGRES_PASSWORD=verif -e POSTGRES_DB=wms postgres:16-alpine >/dev/null
# Se pregunta por TCP: durante initdb la imagen levanta un servidor temporal
# que solo escucha en el socket unix, y sondearlo por ahi da un "listo" falso.
docker exec "$PG" sh -c 'for i in $(seq 1 90); do pg_isready -h 127.0.0.1 -U postgres -q && exit 0; sleep 1; done; exit 1' \
  || { echo "El PostgreSQL de la verificacion no arranco"; exit 1; }
for f in db/migraciones/*.sql; do
  docker exec -i "$PG" psql -U postgres -d wms -v ON_ERROR_STOP=1 --single-transaction -q < "$f" \
    || { echo "FALLO migracion $f"; exit 1; }
done
docker exec -i "$PG" psql -U postgres -d wms -v ON_ERROR_STOP=1 -q < db/semilla.sql >/dev/null \
  || { echo "FALLO semilla"; exit 1; }
echo "OK"

echo '--- API .NET 8 ---'
docker run -d --name "$API" --network "$RED" -p "$PUERTO":8080 \
  -v "$(pwd)":/w -w /w \
  -e ASPNETCORE_URLS='http://+:8080' \
  -e ASPNETCORE_ENVIRONMENT=Development \
  -e WMS_CONEXION="Host=$PG;Port=5432;Database=wms;Username=postgres;Password=verif" \
  mcr.microsoft.com/dotnet/sdk:8.0 \
  dotnet run --project src/Wms.Api/Wms.Api.csproj --no-launch-profile >/dev/null

for _ in $(seq 1 90); do
  curl -sf "$BASE/api/salud" >/dev/null 2>&1 && break; sleep 1
done
curl -sf "$BASE/api/salud" >/dev/null || { echo "FALLO: la API no respondio"; docker logs "$API" | tail -25; exit 1; }
echo "OK"

# Producto y almacen reales de la semilla.
PROD=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select producto_id from wms.tbl_inventario order by producto_id limit 1;")
ALM=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select almacen_id from wms.tbl_inventario order by producto_id limit 1;")
existencia() { docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select cantidad_fisica from wms.tbl_inventario where producto_id=$PROD and almacen_id=$ALM;"; }
cuerpo() { echo "{\"productoId\":$PROD,\"almacenId\":$ALM,\"delta\":$1,\"tipoMovimiento\":\"AJUSTE\",\"motivo\":${2:-null},\"versionEsperada\":null}"; }
post() { # post <idOperacion> <usuario> <delta> [motivo]
  curl -s -w '\n%{http_code}' -X POST "$BASE/api/inventario/ajustar" \
    -H 'Content-Type: application/json' \
    -H "X-Operation-Id: $1" -H "X-Usuario-Id: $2" -H "X-Scope: ajuste:p=$PROD:a=$ALM" \
    -d "$(cuerpo "$3" "${4:-null}")"
}

echo
echo '=== 1) EL ESCENARIO DEL REQUERIMIENTO: modal, conexion lenta, segundo clic ==='
base=$(existencia)
r1=$(post "modal-abc123-0001" 2 2); c1=$(echo "$r1" | tail -1); b1=$(echo "$r1" | head -1)
afirmar "primer clic responde 200" "$c1" "200"
afirmar "primer clic NO es reenvio" "$(campo "$b1" fueReenvio)" "false"
r2=$(post "modal-abc123-0001" 2 2); c2=$(echo "$r2" | tail -1); b2=$(echo "$r2" | head -1)
afirmar "segundo clic responde 200" "$c2" "200"
afirmar "segundo clic SI es reenvio" "$(campo "$b2" fueReenvio)" "true"
afirmar "existencia subio 2, no 4" "$(existencia)" "$((base+2))"
afirmar "un solo movimiento para esa operacion" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where id_operacion='2:modal-abc123-0001';")" "1"

echo
echo '=== 2) REINTENTO TRAS TIMEOUT: el cliente corta, reenvia el MISMO id ==='
base=$(existencia)
curl -s --max-time 0.05 -X POST "$BASE/api/inventario/ajustar" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: timeout-xyz-0001" \
  -H "X-Usuario-Id: 3" -H "X-Scope: ajuste:p=$PROD:a=$ALM" -d "$(cuerpo 5)" >/dev/null 2>&1 || true
sleep 2
# Un 409/WM013 significa "la original sigue corriendo": es correcto y pide
# reintentar. Se reintenta hasta que resuelva, como haria el cliente.
for _ in 1 2 3 4 5 6 7 8; do
  r=$(post "timeout-xyz-0001" 3 5); cod=$(echo "$r" | tail -1)
  [ "$cod" != "409" ] && break
  sleep 2
done
afirmar "el reenvio tras el timeout responde 200" "$cod" "200"
afirmar "el efecto total es +5, no +10" "$(existencia)" "$((base+5))"
afirmar "un solo movimiento pese al corte" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where id_operacion='3:timeout-xyz-0001';")" "1"

echo
echo '=== 3) MOTIVO EDITADO ENTRE REENVIOS: no debe producir WM015 ==='
base=$(existencia)
post "motivo-edit-0001" 2 3 '"conteo ciclico"' >/dev/null
r=$(post "motivo-edit-0001" 2 3 '"conteo ciclico CORREGIDO"'); cod=$(echo "$r" | tail -1)
afirmar "el motivo no participa del hash" "$cod" "200"
afirmar "el efecto sigue siendo +3" "$(existencia)" "$((base+3))"

echo
echo '=== 4) MISMO ID CON CANTIDAD DISTINTA: si debe ser WM015 ==='
r=$(post "motivo-edit-0001" 2 99); cod=$(echo "$r" | tail -1); cuerpo_r=$(echo "$r" | head -1)
afirmar "cambiar la cantidad rompe la huella" "$cod" "409"
afirmar "el codigo de negocio es WM015" "$(campo "$cuerpo_r" codigoWms)" "WM015"

echo
echo '=== 5) AISLAMIENTO POR OPERADOR: el mismo id de cliente NO colisiona ==='
# El prefijo de operador lo antepone el SERVIDOR, no el cliente, asi que dos
# operadores que acunen la misma cadena producen operaciones distintas. Es
# justo lo contrario de una colision: cada intencion se aplica una vez.
base=$(existencia)
r=$(post "modal-abc123-0001" 4 2); cod=$(echo "$r" | tail -1); cuerpo_r=$(echo "$r" | head -1)
afirmar "el otro operador aplica su propia operacion" "$cod" "200"
afirmar "no se la trata como reenvio ajeno" "$(campo "$cuerpo_r" fueReenvio)" "false"
afirmar "el id quedo bajo su propio operador" "$(campo "$cuerpo_r" idOperacion)" "4:modal-abc123-0001"
afirmar "y suma su delta" "$(existencia)" "$((base+2))"
afirmar "son dos movimientos distintos, no uno"   "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where id_operacion like '%:modal-abc123-0001';")" "2"

echo
echo '=== 6) DOS OPERADORES, OPERACIONES DISTINTAS: ambos cuentan ==='
base=$(existencia)
post "concurrente-a-0001" 2 2 >/dev/null &
post "concurrente-b-0001" 3 3 >/dev/null &
wait
afirmar "se aplicaron los dos deltas" "$(existencia)" "$((base+5))"

echo
echo '=== 7) 10 ENVIOS SIMULTANEOS DEL MISMO ID SOBRE HTTP ==='
base=$(existencia)
for _ in $(seq 1 10); do post "rafaga-http-0001" 2 4 >/dev/null & done
wait
afirmar "efecto unico pese a 10 peticiones paralelas" "$(existencia)" "$((base+4))"
afirmar "un solo movimiento" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where id_operacion='2:rafaga-http-0001';")" "1"

echo
echo '=== 8) VALIDACION Y ENCABEZADOS ==='
cod=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/inventario/ajustar" \
  -H 'Content-Type: application/json' -H "X-Usuario-Id: 2" -d "$(cuerpo 1)")
afirmar "sin X-Operation-Id" "$cod" "400"
cod=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/inventario/ajustar" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: sin-usuario-001" -d "$(cuerpo 1)")
afirmar "sin X-Usuario-Id" "$cod" "422"
r=$(post "delta-cero-0001" 2 0); afirmar "delta cero" "$(echo "$r" | tail -1)" "400"
r=$(post "sobreventa-0001" 2 -999999); cod=$(echo "$r" | tail -1); cuerpo_r=$(echo "$r" | head -1)
afirmar "sobreventa" "$cod" "422"
afirmar "codigo de sobreventa" "$(campo "$cuerpo_r" codigoWms)" "WM002"

echo
echo '=== 9) CONSULTAS ==='
afirmar "el tablero responde" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario?porPagina=5")" "200"
afirmar "los movimientos por operacion responden" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/movimientos?idOperacion=2:modal-abc123-0001")" "200"
afirmar "el parser de SKU acepta ELEC-0001" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/sku/analizar?sku=ELEC-0001")" "200"
afirmar "el parser de SKU rechaza elec-1" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/sku/analizar?sku=elec-1")" "422"

echo
echo
echo '=== 11) CICLO DE ORDEN COMPLETO SOBRE HTTP ==='
# Almacen con al menos dos productos con disponible suficiente.
ALM_O=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select almacen_id from wms.tbl_inventario where cantidad_disponible >= 10 group by almacen_id having count(*) >= 2 limit 1;")
P1=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select producto_id from wms.tbl_inventario where almacen_id=$ALM_O and cantidad_disponible >= 10 order by producto_id limit 1;")
P2=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select producto_id from wms.tbl_inventario where almacen_id=$ALM_O and cantidad_disponible >= 10 order by producto_id offset 1 limit 1;")
CLI=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_clientes order by id limit 1;")
res_p1() { docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select cantidad_reservada from wms.tbl_inventario where producto_id=$P1 and almacen_id=$ALM_O;"; }
fis_p1() { docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select cantidad_fisica from wms.tbl_inventario where producto_id=$P1 and almacen_id=$ALM_O;"; }

crear() { curl -s -w '\n%{http_code}' -X POST "$BASE/api/ordenes" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: $1" -H "X-Usuario-Id: $2" -H "X-Scope: orden:alta" \
  -d "{\"clienteId\":$CLI,\"almacenId\":$ALM_O,\"notas\":${3:-null},\"partidas\":[{\"productoId\":$P1,\"cantidad\":4},{\"productoId\":$P2,\"cantidad\":3}]}"; }
# accion <verbo> <idOperacion> <ordenId> [cuerpo] [usuario]
accion() { curl -s -w '\n%{http_code}' -X POST "$BASE/api/ordenes/$3/$1" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: $2" -H "X-Usuario-Id: ${5:-2}" -H "X-Scope: orden:$1:$3" \
  -d "${4:-{\}}"; }

r=$(crear "orden-alta-0001" 2); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
ORD=$(campo "$cu" id); FOLIO=$(campo "$cu" folio)
afirmar "el alta responde 201" "$cod" "201"
afirmar "la orden nace en BORRADOR" "$(campo "$cu" estatus)" "BORRADOR"
afirmar "el total lo calculo el trigger" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select monto_total > 0 from wms.tbl_ordenes where id=$ORD;")" "t"
afirmar "las dos partidas quedaron selladas" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.rel_orden_producto where orden_id=$ORD and nombre_historico <> '' and precio_unitario_historico > 0;")" "2"

echo
echo '=== 12) REENVIO DEL ALTA: no debe crear una segunda orden ==='
r=$(crear "orden-alta-0001" 2); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "el reenvio del alta responde 200" "$cod" "200"
afirmar "devuelve el MISMO folio" "$(campo "$cu" folio)" "$FOLIO"
afirmar "se marca como reenvio" "$(campo "$cu" fueReenvio)" "true"
afirmar "hay una sola orden con ese id_operacion" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_ordenes where id_operacion='2:orden-alta-0001';")" "1"

echo
echo '=== 13) TRANSICION INVALIDA: enviar sin confirmar ==='
r=$(accion enviar "orden-envio-malo-01" "$ORD"); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "enviar desde BORRADOR" "$cod" "409"
afirmar "codigo de transicion invalida" "$(campo "$cu" codigoWms)" "WM001"

echo
echo '=== 14) CONFIRMAR: reserva sin tocar la existencia fisica ==='
res_antes=$(res_p1); fis_antes=$(fis_p1)
r=$(accion confirmar "orden-conf-0001" "$ORD"); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "la confirmacion responde 200" "$cod" "200"
afirmar "la orden queda CONFIRMADA" "$(campo "$cu" estatus)" "CONFIRMADA"
afirmar "la reserva subio 4" "$(res_p1)" "$((res_antes+4))"
afirmar "la existencia fisica NO cambio" "$(fis_p1)" "$fis_antes"

echo
echo '=== 15) REENVIO DE LA CONFIRMACION: sin doble reserva ==='
res_antes=$(res_p1)
r=$(accion confirmar "orden-conf-0001" "$ORD"); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "el reenvio responde 200" "$cod" "200"
afirmar "se marca como reenvio" "$(campo "$cu" fueReenvio)" "true"
afirmar "la reserva NO se duplico" "$(res_p1)" "$res_antes"

echo
echo '=== 16) ENVIAR: descuenta fisico y libera reserva ==='
res_antes=$(res_p1); fis_antes=$(fis_p1)
r=$(accion enviar "orden-envio-0001" "$ORD"); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "el envio responde 200" "$cod" "200"
afirmar "la orden queda ENVIADA" "$(campo "$cu" estatus)" "ENVIADA"
afirmar "la existencia fisica bajo 4" "$(fis_p1)" "$((fis_antes-4))"
afirmar "la reserva se libero" "$(res_p1)" "$((res_antes-4))"
afirmar "el embarque quedo en la bitacora" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where orden_id=$ORD and tipo_movimiento='EMBARQUE';")" "2"

echo
echo '=== 17) ENVIADA ES TERMINAL ==='
r=$(accion cancelar "orden-canc-mala-01" "$ORD" '{"motivo":"tarde"}')
cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "cancelar una orden enviada" "$cod" "409"
afirmar "codigo de transicion invalida" "$(campo "$cu" codigoWms)" "WM001"

echo
echo '=== 18) CANCELAR UNA CONFIRMADA: libera reserva, no toca fisico ==='
r=$(crear "orden-alta-0002" 3); ORD2=$(campo "$(echo "$r" | head -1)" id)
accion confirmar "orden-conf-0002" "$ORD2" >/dev/null
res_antes=$(res_p1); fis_antes=$(fis_p1)
r=$(accion cancelar "orden-canc-0002" "$ORD2" '{"motivo":"el cliente desistio"}' 4)
cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "la cancelacion responde 200" "$cod" "200"
afirmar "la orden queda CANCELADA" "$(campo "$cu" estatus)" "CANCELADA"
afirmar "la reserva se libero" "$(res_p1)" "$((res_antes-4))"
afirmar "la existencia fisica NO cambio" "$(fis_p1)" "$fis_antes"
# Creo el 3, cancelo el 4: la trazabilidad los distingue.
afirmar "quedo registrado quien CREO" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select creado_por_usuario_id from wms.tbl_ordenes where id=$ORD2;")" "3"
afirmar "y quien CANCELO, que es otro" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select cancelado_por_usuario_id from wms.tbl_ordenes where id=$ORD2;")" "4"
afirmar "la liberacion quedo atribuida al que cancelo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select distinct usuario_id from wms.tbl_movimientos_inventario where orden_id=$ORD2 and tipo_movimiento='LIBERACION';")" "4"

echo
echo '=== 19) EXISTENCIA INSUFICIENTE AL CONFIRMAR ==='
r=$(curl -s -w '\n%{http_code}' -X POST "$BASE/api/ordenes" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: orden-alta-0003" -H "X-Usuario-Id: 2" -H "X-Scope: orden:alta" \
  -d "{\"clienteId\":$CLI,\"almacenId\":$ALM_O,\"notas\":null,\"partidas\":[{\"productoId\":$P1,\"cantidad\":999999}]}")
ORD3=$(campo "$(echo "$r" | head -1)" id)
r=$(accion confirmar "orden-conf-0003" "$ORD3"); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "confirmar sin existencia" "$cod" "422"
afirmar "codigo de existencia insuficiente" "$(campo "$cu" codigoWms)" "WM002"
afirmar "la orden sigue en BORRADOR tras el rollback" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select estatus from wms.tbl_ordenes where id=$ORD3;")" "BORRADOR"

echo
echo '=== 20) VALIDACION DE ORDENES ==='
cod=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/ordenes" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: orden-sin-partidas1" -H "X-Usuario-Id: 2" \
  -d "{\"clienteId\":$CLI,\"almacenId\":$ALM_O,\"notas\":null,\"partidas\":[]}")
afirmar "orden sin partidas" "$cod" "400"
cod=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/ordenes" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: orden-producto-dup1" -H "X-Usuario-Id: 2" \
  -d "{\"clienteId\":$CLI,\"almacenId\":$ALM_O,\"notas\":null,\"partidas\":[{\"productoId\":$P1,\"cantidad\":1},{\"productoId\":$P1,\"cantidad\":2}]}")
afirmar "producto repetido en la misma orden" "$cod" "400"
cod=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/ordenes/$ORD/cancelar" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: cancelar-sin-motivo1" -H "X-Usuario-Id: 2" -d '{"motivo":""}')
afirmar "cancelar sin motivo" "$cod" "400"

echo
echo '=== 21) CONSULTAS DE ORDENES, CATALOGOS E INDICADORES ==='
afirmar "listado de ordenes" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/ordenes?porPagina=5")" "200"
afirmar "filtro por estatus" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/ordenes?estatus=ENVIADA")" "200"
afirmar "partidas de la orden" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/ordenes/$ORD/partidas")" "200"
for cat in categorias almacenes clientes usuarios productos; do
  afirmar "catalogo $cat" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/catalogos/$cat")" "200"
done
afirmar "catalogo inexistente" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/catalogos/inventado")" "404"
ind=$(curl -s "$BASE/api/indicadores")
afirmar "indicadores responden" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/indicadores")" "200"
afirmar "los indicadores traen la serie diaria" \
  "$(echo "$ind" | grep -c 'serieDiaria')" "1"
afirmar "los indicadores traen aportacion por usuario" \
  "$(echo "$ind" | grep -c 'aportacionPorUsuario')" "1"

echo
echo
echo '=== 22) IMPORTACION: plantilla descargable ==='
# curl aqui es un binario nativo de Windows y no resuelve rutas POSIX
# (/tmp/...). Se usa un directorio relativo al repo, que si ve.
TMPD=.tmp-verificacion
rm -rf "$TMPD"; mkdir -p "$TMPD"
curl -s "$BASE/api/importacion/plantilla" -o "$TMPD/plantilla.csv"
afirmar "la plantilla se descarga" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/importacion/plantilla")" "200"
afirmar "trae el encabezado exacto" \
  "$(tail -c +4 "$TMPD/plantilla.csv" | head -1 | tr -d '\r')" \
  "categoria_codigo,nombre_producto,descripcion,precio_unitario,estatus,almacen_codigo,cantidad_inicial,cantidad_minima"

# Importar como SISTEMA por omision: desde 0006, crear productos nuevos es un
# alta de catalogo y solo el usuario 1 puede hacerla. La prueba 45 verifica
# aparte que un operador cualquiera SI queda bloqueado.
importar() { curl -s -w '\n%{http_code}' -X POST "$BASE/api/importacion" \
  -H "X-Usuario-Id: ${3:-1}" -F "archivo=@$1" -F "modo=${2:-SOLO_ALTA}"; }

echo
echo '=== 23) IMPORTACION CON MEZCLA DE VALIDOS E INVALIDOS ==='
cat > "$TMPD/mixto.csv" <<'CSV'
categoria_codigo,nombre_producto,descripcion,precio_unitario,estatus,almacen_codigo,cantidad_inicial,cantidad_minima
ELEC,Producto Importado Uno,"Descripcion, con coma",100.50,ACTIVO,ALM-NTE,10,2
ELEC,Producto Importado Dos,,200.00,ACTIVO,ALM-NTE,5,1
XXXX,Categoria Fantasma,,50.00,ACTIVO,ALM-NTE,1,0
ELEC,Almacen Fantasma,,50.00,ACTIVO,ALM-ZZZ,1,0
ELEC,Precio Malo,,no-es-precio,ACTIVO,ALM-NTE,1,0
ELEC,Cantidad Mala,,10.00,ACTIVO,ALM-NTE,-5,0
ELEC,Producto Importado Uno,,100.50,ACTIVO,ALM-NTE,7,0
CSV
r=$(importar "$TMPD/mixto.csv" SOLO_ALTA); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
LOTE=$(campo "$cu" loteId)
afirmar "la importacion responde 200" "$cod" "200"
afirmar "2 renglones aplicados" "$(campo "$cu" renglonesOk)" "2"
afirmar "5 renglones con error" "$(campo "$cu" renglonesError)" "5"
afirmar "estatus del lote" "$(campo "$cu" estatus)" "COMPLETADO_CON_ERRORES"
afirmar "detecto el duplicado dentro del archivo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_renglones_importacion where lote_id=$LOTE and codigo_error='DUPLICADO_EN_ARCHIVO';")" "1"
afirmar "detecto la categoria inexistente" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_renglones_importacion where lote_id=$LOTE and codigo_error='CATEGORIA_INEXISTENTE';")" "1"
afirmar "detecto el almacen inexistente" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_renglones_importacion where lote_id=$LOTE and codigo_error='ALMACEN_INEXISTENTE';")" "1"
afirmar "acuno SKUs para los productos nuevos" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_productos where nombre like 'Producto Importado%';")" "2"
afirmar "el campo entrecomillado con coma se leyo bien" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select descripcion from wms.cat_productos where nombre='Producto Importado Uno';")" "Descripcion, con coma"
afirmar "aplico las existencias" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select i.cantidad_fisica from wms.tbl_inventario i join wms.cat_productos p on p.id=i.producto_id where p.nombre='Producto Importado Uno';")" "10"

echo
echo '=== 24) REIMPORTAR EL MISMO ARCHIVO: no debe duplicar existencias ==='
fis_antes=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "select i.cantidad_fisica from wms.tbl_inventario i join wms.cat_productos p on p.id=i.producto_id where p.nombre='Producto Importado Uno';")
r=$(importar "$TMPD/mixto.csv" SOLO_ALTA); cu=$(echo "$r" | head -1)
afirmar "reanuda el MISMO lote" "$(campo "$cu" loteId)" "$LOTE"
afirmar "se marca como reanudacion" "$(campo "$cu" fueReanudacion)" "true"
afirmar "la existencia NO se duplico" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select i.cantidad_fisica from wms.tbl_inventario i join wms.cat_productos p on p.id=i.producto_id where p.nombre='Producto Importado Uno';")" "$fis_antes"
afirmar "no se creo un segundo lote para ese archivo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_lotes_importacion where nombre_archivo='mixto.csv';")" "1"
afirmar "no se duplicaron los productos" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_productos where nombre like 'Producto Importado%';")" "2"

echo
echo '=== 25) MODO ALTA_O_ACTUALIZA ==='
cat > "$TMPD/actualiza.csv" <<'CSV'
categoria_codigo,nombre_producto,descripcion,precio_unitario,estatus,almacen_codigo,cantidad_inicial,cantidad_minima
ELEC,Producto Importado Uno,Descripcion actualizada,999.99,ACTIVO,ALM-NTE,3,4
CSV
r=$(importar "$TMPD/actualiza.csv" ALTA_O_ACTUALIZA); cu=$(echo "$r" | head -1)
afirmar "un renglon aplicado" "$(campo "$cu" renglonesOk)" "1"
afirmar "actualizo el precio" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select precio_unitario from wms.cat_productos where nombre='Producto Importado Uno';")" "999.99"
afirmar "sumo la cantidad al inventario existente" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select i.cantidad_fisica from wms.tbl_inventario i join wms.cat_productos p on p.id=i.producto_id where p.nombre='Producto Importado Uno';")" "$((fis_antes+3))"
afirmar "el mismo archivo en SOLO_ALTA habria omitido" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_renglones_importacion r join wms.tbl_lotes_importacion l on l.id=r.lote_id where l.modo='ALTA_O_ACTUALIZA' and r.accion='ACTUALIZACION';")" "1"

echo
echo '=== 26) ARCHIVO 100% INVALIDO: nunca abre transaccion de trabajo ==='
cat > "$TMPD/malo.csv" <<'CSV'
categoria_codigo,nombre_producto,descripcion,precio_unitario,estatus,almacen_codigo,cantidad_inicial,cantidad_minima
XXXX,Fantasma A,,10.00,ACTIVO,ALM-NTE,1,0
YYYY,Fantasma B,,10.00,ACTIVO,ALM-NTE,1,0
CSV
r=$(importar "$TMPD/malo.csv" SOLO_ALTA); cu=$(echo "$r" | head -1)
afirmar "cero renglones aplicados" "$(campo "$cu" renglonesOk)" "0"
afirmar "el lote queda FALLIDO" "$(campo "$cu" estatus)" "FALLIDO"

echo
echo '=== 27) ENCABEZADO EQUIVOCADO ==='
cat > "$TMPD/encabezado.csv" <<'CSV'
categoria,nombre,precio
ELEC,Algo,10
CSV
r=$(importar "$TMPD/encabezado.csv"); cu=$(echo "$r" | head -1)
afirmar "rechaza el encabezado" "$(campo "$cu" estatus)" "FALLIDO"
afirmar "con codigo COLUMNAS_INVALIDAS" \
  "$(echo "$cu" | grep -c 'COLUMNAS_INVALIDAS')" "1"

echo
echo '=== 28) RESULTADO CONSULTABLE DESPUES ==='
afirmar "el resultado del lote se consulta" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/importacion/$LOTE")" "200"
afirmar "un lote inexistente da 404" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/importacion/999999")" "404"
det=$(curl -s "$BASE/api/importacion/$LOTE")
afirmar "trae el resumen agrupado" "$(echo "$det" | grep -c 'resumen')" "1"
afirmar "trae el detalle por renglon" "$(echo "$det" | grep -c 'renglones')" "1"
afirmar "conserva la carga original de cada renglon" "$(echo "$det" | grep -c 'carga_original')" "1"
# Los renglones del lote llegan en la MISMA envoltura paginada que el resto de
# los listados: antes se recortaban con un limit mudo de 1000.
afirmar "los renglones llegan paginados" \
  "$(echo "$det" | grep -c '"renglones":{"elementos"')" "1"
det1=$(curl -s "$BASE/api/importacion/$LOTE?pagina=1&porPagina=1")
afirmar "porPagina=1 devuelve un solo renglon" \
  "$(echo "$det1" | grep -o '"numero_renglon"' | wc -l | tr -d ' ')" "1"
afirmar "el total describe el lote entero, no la pagina" \
  "$(echo "$det1" | grep -o '"renglones":{"elementos":\[.*\],"total":[0-9]*' | grep -o '"total":[0-9]*$' | cut -d: -f2)" \
  "$(echo "$det" | grep -o '"renglones_total":[0-9]*' | head -1 | cut -d: -f2)"

echo
echo '=== 29) SIN ARCHIVO ==='
afirmar "peticion sin archivo" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/importacion" -H 'X-Usuario-Id: 2' -F 'modo=SOLO_ALTA')" "400"

rm -rf "$TMPD"

echo
echo '=== 30) EXPORTACION DE INVENTARIO ==='
mkdir -p "$TMPD"   # el bloque de importacion lo borro al terminar
# La semilla crea a Ana (id 2) como SUPERVISOR y a Bruno (id 3) como OPERADOR.
cod=$(curl -s -o "$TMPD/export.csv" -w '%{http_code}' "$BASE/api/inventario/exportar" -H 'X-Usuario-Id: 2')
afirmar "un SUPERVISOR puede exportar" "$cod" "200"
afirmar "trae encabezados legibles" \
  "$(tail -c +4 "$TMPD/export.csv" | head -1 | tr -d '\r' | cut -d, -f1-4)" \
  "SKU,Producto,Categoría,Almacén"
total=$(($(wc -l < "$TMPD/export.csv") - 1))
afirmar "exporta todo el inventario" "$total" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c 'select count(*) from wms.tbl_inventario;')"

echo '--- respeta los filtros aplicados ---'
curl -s -o "$TMPD/export_bajas.csv" "$BASE/api/inventario/exportar?soloExistenciaBaja=true" -H 'X-Usuario-Id: 2'
afirmar "el filtro de existencia baja se respeta" \
  "$(($(wc -l < "$TMPD/export_bajas.csv") - 1))" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c 'select productos_existencia_baja from wms.vw_indicadores_operacion;')"

ALM1=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_almacenes order by id limit 1;")
curl -s -o "$TMPD/export_alm.csv" "$BASE/api/inventario/exportar?almacenId=$ALM1" -H 'X-Usuario-Id: 2'
afirmar "el filtro de almacen se respeta" \
  "$(($(wc -l < "$TMPD/export_alm.csv") - 1))" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_inventario where almacen_id=$ALM1;")"

echo '--- permisos ---'
r=$(curl -s -w '\n%{http_code}' "$BASE/api/inventario/exportar" -H 'X-Usuario-Id: 3')
afirmar "un OPERADOR no puede exportar" "$(echo "$r" | tail -1)" "403"
afirmar "codigo de permiso" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM017"
afirmar "sin operador declarado" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/exportar")" "422"

echo
echo '=== 31) BUSQUEDA DE PRODUCTOS (LIKE parcial) ==='
afirmar "busca por fragmento de SKU" \
  "$(curl -s "$BASE/api/productos/buscar?q=ELEC-00" | grep -o '"sku"' | wc -l | tr -d ' ')" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select least(count(*),20) from wms.cat_productos where sku ilike '%ELEC-00%' and estatus='ACTIVO';")"
hay=$(curl -s "$BASE/api/productos/buscar?q=able" | grep -o '"id"' | wc -l | tr -d ' ')
afirmar "busca por fragmento del nombre" "$([ "$hay" -gt 0 ] && echo si || echo no)" "si"
afirmar "devuelve el identificador real, no el texto" \
  "$(curl -s "$BASE/api/productos/buscar?q=ELEC-0001" | grep -oE '"id":[0-9]+' | head -1 | cut -d: -f2)" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_productos where sku='ELEC-0001';")"
afirmar "menos de dos caracteres no dispara consulta" \
  "$(curl -s "$BASE/api/productos/buscar?q=E")" "[]"
afirmar "sin coincidencias devuelve lista vacia" \
  "$(curl -s "$BASE/api/productos/buscar?q=zzzznoexiste")" "[]"
afirmar "el limite se respeta" \
  "$(curl -s "$BASE/api/productos/buscar?q=ca&limite=3" | grep -o '"id"' | wc -l | tr -d ' ')" "3"

echo
echo '=== 32) AJUSTE MANUAL A CANTIDAD OBJETIVO ==='
PR=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select producto_id from wms.tbl_inventario where cantidad_reservada=0 order by producto_id limit 1;")
AL=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select almacen_id from wms.tbl_inventario where cantidad_reservada=0 order by producto_id limit 1;")
ver() { docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.tbl_inventario where producto_id=$PR and almacen_id=$AL;"; }
fis() { docker exec "$PG" psql -U postgres -d wms -qtAX -c "select cantidad_fisica from wms.tbl_inventario where producto_id=$PR and almacen_id=$AL;"; }
establecer() { curl -s -w '\n%{http_code}' -X POST "$BASE/api/inventario/establecer" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: $1" -H "X-Usuario-Id: ${3:-2}" -H 'X-Scope: establecer' \
  -d "{\"productoId\":$PR,\"almacenId\":$AL,\"cantidadObjetivo\":$2,\"motivo\":\"conteo fisico\",\"versionEsperada\":${4:-null}}"; }

antes=$(fis)
r=$(establecer "establecer-0001" 777); cod=$(echo "$r" | tail -1); cu=$(echo "$r" | head -1)
afirmar "establece la cantidad objetivo" "$cod" "200"
afirmar "la existencia queda en el objetivo" "$(fis)" "777"
afirmar "genero un movimiento AJUSTE auditable" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where id_operacion='2:establecer-0001' and tipo_movimiento='AJUSTE';")" "1"
afirmar "el delta registrado es el real" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select delta_fisica from wms.tbl_movimientos_inventario where id_operacion='2:establecer-0001';")" \
  "$((777-antes))"

echo '--- idempotencia del ajuste manual ---'
r=$(establecer "establecer-0001" 777); cu=$(echo "$r" | head -1)
afirmar "el reenvio es reenvio" "$(campo "$cu" fueReenvio)" "true"
afirmar "la existencia no cambio" "$(fis)" "777"

echo '--- concurrencia optimista sobre cantidad absoluta ---'
vactual=$(ver)
r=$(establecer "establecer-viejo-01" 500 2 "$((vactual - 1))")
afirmar "una version obsoleta se rechaza" "$(echo "$r" | tail -1)" "409"
afirmar "codigo de concurrencia" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM008"
afirmar "la existencia sigue intacta" "$(fis)" "777"
r=$(establecer "establecer-fresco-1" 500 2 "$vactual")
afirmar "con la version vigente si aplica" "$(echo "$r" | tail -1)" "200"

echo '--- validaciones ---'
afirmar "objetivo negativo" "$(echo "$(establecer 'establecer-neg-01' -5)" | tail -1)" "400"
r=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/inventario/establecer" \
  -H 'Content-Type: application/json' -H 'X-Operation-Id: establecer-dec-01' -H 'X-Usuario-Id: 2' \
  -d "{\"productoId\":$PR,\"almacenId\":$AL,\"cantidadObjetivo\":1.5,\"motivo\":null,\"versionEsperada\":null}")
afirmar "objetivo decimal" "$r" "400"

echo '--- no puede quedar por debajo de lo reservado ---'
PR2=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select producto_id from wms.tbl_inventario where cantidad_reservada > 0 order by producto_id limit 1;")
AL2=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select almacen_id from wms.tbl_inventario where cantidad_reservada > 0 order by producto_id limit 1;")
r=$(curl -s -w '\n%{http_code}' -X POST "$BASE/api/inventario/establecer" \
  -H 'Content-Type: application/json' -H 'X-Operation-Id: establecer-reserva1' -H 'X-Usuario-Id: 2' \
  -d "{\"productoId\":$PR2,\"almacenId\":$AL2,\"cantidadObjetivo\":0,\"motivo\":\"prueba\",\"versionEsperada\":null}")
afirmar "objetivo por debajo de lo reservado" "$(echo "$r" | tail -1)" "422"
afirmar "codigo de existencia" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM002"

echo
echo '=== 33) FILTROS DE MOVIMIENTOS ==='
USR=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select usuario_id from wms.tbl_movimientos_inventario group by usuario_id order by count(*) desc limit 1;")
# n() cuenta OCURRENCIAS; la respuesta JSON viene en una sola linea.
n() { grep -o "$2" <<< "$1" | wc -l | tr -d ' '; }
resp=$(curl -s "$BASE/api/inventario/movimientos?usuarioId=$USR&porPagina=200&desde=2000-01-01")
afirmar "filtro por usuario: todo el resultado es de ese usuario" \
  "$(n "$resp" "\"usuarioId\":$USR")" "$(n "$resp" '"uuidMovimiento"')"
afirmar "y el total corresponde al filtro" \
  "$(node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).total))" <<< "$resp")" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where usuario_id=$USR;")"
resp=$(curl -s "$BASE/api/inventario/movimientos?sku=ELEC-0001&porPagina=200&desde=2000-01-01")
afirmar "filtro por SKU: todo el resultado es de ese SKU" \
  "$(n "$resp" '"productoSku":"ELEC-0001"')" "$(n "$resp" '"uuidMovimiento"')"
resp=$(curl -s "$BASE/api/inventario/movimientos?porPagina=200")
afirmar "ventana por omision de 30 dias" \
  "$(node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).total))" <<< "$resp")" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select least(count(*),500) from wms.tbl_movimientos_inventario where creado_en >= (now() at time zone 'utc')::date - interval '30 days';")"
afirmar "rango invertido se rechaza" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/movimientos?desde=2026-08-20&hasta=2026-08-10")" "400"
afirmar "fecha final inclusiva" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/movimientos?desde=2026-08-01&hasta=2026-08-22")" "200"
afirmar "filtros combinados" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/movimientos?usuarioId=$USR&sku=ELEC&desde=2026-07-01&hasta=2026-08-31&tipo=ENTRADA")" "200"

echo
echo '=== 34) KPI NUEVOS ==='
ind=$(curl -s "$BASE/api/indicadores?dias=60&topN=5")
afirmar "el tablero trae mayor demanda" "$(echo "$ind" | grep -c 'mayorDemanda')" "1"
afirmar "el tablero trae existencia insuficiente" "$(echo "$ind" | grep -c 'existenciaInsuficiente')" "1"
afirmar "la demanda respeta el topN" \
  "$(echo "$ind" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).mayorDemanda.length))")" "5"
afirmar "la demanda trae posicion, sku y unidades" \
  "$(echo "$ind" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const x=JSON.parse(d).mayorDemanda[0];console.log([x.posicion!=null,x.producto_sku!=null,x.unidades_demandadas!=null].every(Boolean))})")" "true"
afirmar "el faltante trae existencia, minimo y diferencia" \
  "$(echo "$ind" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const x=JSON.parse(d).existenciaInsuficiente[0];console.log([x.cantidad_disponible!=null,x.cantidad_minima!=null,x.faltante!=null].every(Boolean))})")" "true"

echo
echo '=== 35) DETALLE Y DESACTIVACION DE MOVIMIENTOS ==='
MOV=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.tbl_movimientos_inventario where tipo_origen <> 'ORDEN' and delta_fisica < 0 and not exists (select 1 from wms.tbl_movimientos_inventario r where r.movimiento_revertido_id = wms.tbl_movimientos_inventario.id) order by id desc limit 1;")
afirmar "cualquier operador consulta el detalle" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/movimientos/$MOV" -H 'X-Usuario-Id: 3')" "200"
det=$(curl -s "$BASE/api/inventario/movimientos/$MOV")
afirmar "el detalle trae id_operacion" "$(echo "$det" | grep -c 'id_operacion')" "1"
afirmar "el detalle trae el estado" "$(echo "$det" | grep -c '"estado"')" "1"
afirmar "movimiento inexistente" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/movimientos/99999999")" "404"

desactivar() { curl -s -w '\n%{http_code}' -X POST "$BASE/api/inventario/movimientos/$2/desactivar" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: $1" -H "X-Usuario-Id: ${3:-1}" -H 'X-Scope: mov:desactivar' \
  -d '{"motivo":"error de captura"}'; }

echo '--- la restriccion vive en backend, no en el boton ---'
r=$(desactivar "desactivar-op-001" "$MOV" 3)
afirmar "un operador cualquiera recibe 403" "$(echo "$r" | tail -1)" "403"
afirmar "codigo de restriccion" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM018"
afirmar "el movimiento sigue activo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select esta_desactivado from wms.vw_movimientos_detalle where id=$MOV;")" "f"

echo '--- el usuario 1 (SISTEMA) si puede ---'
fis_antes=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select i.cantidad_fisica from wms.tbl_inventario i join wms.tbl_movimientos_inventario m on m.producto_id=i.producto_id and m.almacen_id=i.almacen_id where m.id=$MOV;")
delta=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select delta_fisica from wms.tbl_movimientos_inventario where id=$MOV;")
r=$(desactivar "desactivar-sis-001" "$MOV" 1)
afirmar "el usuario SISTEMA desactiva" "$(echo "$r" | tail -1)" "200"
afirmar "la existencia se compenso" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select i.cantidad_fisica from wms.tbl_inventario i join wms.tbl_movimientos_inventario m on m.producto_id=i.producto_id and m.almacen_id=i.almacen_id where m.id=$MOV;")" \
  "$((fis_antes - delta))"
afirmar "el movimiento queda marcado desactivado" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select esta_desactivado from wms.vw_movimientos_detalle where id=$MOV;")" "t"
afirmar "el original conserva su delta original" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select delta_fisica from wms.tbl_movimientos_inventario where id=$MOV;")" "$delta"
afirmar "quedo registrado quien lo desactivo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select desactivado_por_nombre from wms.vw_movimientos_detalle where id=$MOV;")" "Sistema"

echo '--- doble clic / reintento ---'
r=$(desactivar "desactivar-sis-001" "$MOV" 1)
afirmar "el reenvio del mismo id es idempotente" "$(echo "$r" | tail -1)" "200"
r=$(desactivar "desactivar-sis-002" "$MOV" 1)
afirmar "un id nuevo sobre lo ya desactivado se rechaza" "$(echo "$r" | tail -1)" "409"
afirmar "codigo de no-repetible" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM019"
afirmar "una sola reversa en la bitacora" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario where movimiento_revertido_id=$MOV;")" "1"

echo '--- desactivar exige motivo ---'
MOV2=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.tbl_movimientos_inventario where tipo_origen <> 'ORDEN' and delta_fisica < 0 and movimiento_revertido_id is null and not exists (select 1 from wms.tbl_movimientos_inventario r where r.movimiento_revertido_id = wms.tbl_movimientos_inventario.id) order by id desc limit 1;")
afirmar "sin motivo" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/inventario/movimientos/$MOV2/desactivar" \
     -H 'Content-Type: application/json' -H 'X-Operation-Id: desactivar-nomot-1' -H 'X-Usuario-Id: 1' -d '{"motivo":""}')" "400"

echo '--- un movimiento de ORDEN no se desactiva ---'
MOVORD=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.tbl_movimientos_inventario where tipo_origen='ORDEN' order by id desc limit 1;")
r=$(desactivar "desactivar-orden-1" "$MOVORD" 1)
afirmar "movimiento de orden" "$(echo "$r" | tail -1)" "409"
afirmar "codigo" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM019"

echo '--- el invariante sigue en pie tras las reversas ---'
afirmar "sum(delta_fisica) = cantidad_fisica" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select bool_and(ok) from (select i.cantidad_fisica = coalesce((select sum(m.delta_fisica) from wms.tbl_movimientos_inventario m where m.producto_id=i.producto_id and m.almacen_id=i.almacen_id),0) as ok from wms.tbl_inventario i) t;")" "t"

echo
echo '=== 40) PAGINACION DE 25 POR PAGINA ==='
json() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const x=JSON.parse(d);console.log(eval(process.argv[1]))})" "$1"; }

INV_TOTAL=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c 'select count(*) from wms.tbl_inventario;')
p1=$(curl -s "$BASE/api/inventario")
afirmar "hay mas de 25 registros para paginar" \
  "$([ "$INV_TOTAL" -gt 25 ] && echo si || echo no)" "si"
afirmar "la pagina trae 25 elementos" "$(json 'x.elementos.length' <<< "$p1")" "25"
afirmar "el total es el del conjunto completo" "$(json 'x.total' <<< "$p1")" "$INV_TOTAL"
afirmar "reporta la pagina actual" "$(json 'x.numeroPagina' <<< "$p1")" "1"
afirmar "calcula el total de paginas" "$(json 'x.totalPaginas' <<< "$p1")" \
  "$(node -e "console.log(Math.ceil($INV_TOTAL/25))")"
afirmar "no hay pagina anterior en la primera" "$(json 'x.hayAnterior' <<< "$p1")" "false"
afirmar "si hay siguiente" "$(json 'x.haySiguiente' <<< "$p1")" "true"

p2=$(curl -s "$BASE/api/inventario?pagina=2")
afirmar "la pagina 2 trae otros registros" \
  "$([ "$(json 'x.elementos[0].productoSku' <<< "$p1")" != "$(json 'x.elementos[0].productoSku' <<< "$p2")" ] && echo si || echo no)" "si"
afirmar "la pagina 2 conserva el total" "$(json 'x.total' <<< "$p2")" "$INV_TOTAL"
afirmar "la pagina 2 si tiene anterior" "$(json 'x.hayAnterior' <<< "$p2")" "true"

ultima=$(node -e "console.log(Math.ceil($INV_TOTAL/25))")
pu=$(curl -s "$BASE/api/inventario?pagina=$ultima")
afirmar "la ultima pagina no tiene siguiente" "$(json 'x.haySiguiente' <<< "$pu")" "false"
afirmar "una pagina fuera de rango viene vacia" \
  "$(json 'x.elementos.length' <<< "$(curl -s "$BASE/api/inventario?pagina=9999")")" "0"

echo '--- la consulta pagina en la BASE, no en el navegador ---'
afirmar "pedir pagina 2 no descarga todo" \
  "$(json 'x.elementos.length' <<< "$p2")" "25"

echo
echo '=== 41) LOS FILTROS SOBREVIVEN A LA PAGINACION ==='
ALMP=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select almacen_id from wms.tbl_inventario group by almacen_id order by count(*) desc limit 1;")
TOTAL_ALM=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_inventario where almacen_id=$ALMP;")
f1=$(curl -s "$BASE/api/inventario?almacenId=$ALMP")
afirmar "el total refleja el FILTRO, no la tabla entera" "$(json 'x.total' <<< "$f1")" "$TOTAL_ALM"
f2=$(curl -s "$BASE/api/inventario?almacenId=$ALMP&pagina=2")
afirmar "la pagina 2 mantiene el filtro" "$(json 'x.total' <<< "$f2")" "$TOTAL_ALM"
afirmar "todos los renglones filtrados son del almacen" \
  "$(json 'x.elementos.every(e=>e.almacenId==='"$ALMP"')' <<< "$f2")" "true"

echo '--- cambiar el filtro cambia el conjunto y su conteo ---'
fb=$(curl -s "$BASE/api/inventario?soloExistenciaBaja=true")
afirmar "otro filtro, otro total" \
  "$(json 'x.total' <<< "$fb")" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c 'select productos_existencia_baja from wms.vw_indicadores_operacion;')"

echo
echo '=== 42) PAGINACION EN MOVIMIENTOS Y ORDENES ==='
mp=$(curl -s "$BASE/api/inventario/movimientos?desde=2000-01-01")
MOV_TOTAL=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.tbl_movimientos_inventario;")
afirmar "movimientos: 25 por pagina" "$(json 'x.elementos.length' <<< "$mp")" "25"
afirmar "movimientos: total correcto" "$(json 'x.total' <<< "$mp")" "$MOV_TOTAL"
afirmar "movimientos: orden descendente por fecha" \
  "$(json 'new Date(x.elementos[0].creadoEn) >= new Date(x.elementos[24].creadoEn)' <<< "$mp")" "true"
mp2=$(curl -s "$BASE/api/inventario/movimientos?desde=2000-01-01&pagina=2")
afirmar "movimientos: la pagina 2 no repite la 1" \
  "$([ "$(json 'x.elementos[0].id' <<< "$mp")" != "$(json 'x.elementos[0].id' <<< "$mp2")" ] && echo si || echo no)" "si"

op=$(curl -s "$BASE/api/ordenes")
afirmar "ordenes: reporta total" \
  "$(json 'x.total' <<< "$op")" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c 'select count(*) from wms.tbl_ordenes;')"

echo
echo '=== 43) EXPORTAR NO SE LIMITA A LA PAGINA VISIBLE ==='
mkdir -p "$TMPD"
curl -s -o "$TMPD/exp_todo.csv" "$BASE/api/inventario/exportar" -H 'X-Usuario-Id: 2'
afirmar "exporta TODOS los filtrados, no los 25 de la pagina" \
  "$(($(wc -l < "$TMPD/exp_todo.csv") - 1))" "$INV_TOTAL"
curl -s -o "$TMPD/exp_alm.csv" "$BASE/api/inventario/exportar?almacenId=$ALMP" -H 'X-Usuario-Id: 2'
afirmar "con filtro exporta todo el filtro, no la pagina" \
  "$(($(wc -l < "$TMPD/exp_alm.csv") - 1))" "$TOTAL_ALM"

echo
echo '=== 44) ALTA EN CATALOGOS: SOLO EL USUARIO 1 ==='
alta() { curl -s -w '\n%{http_code}' -X POST "$BASE/api/catalogos/$2" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: $1" -H "X-Usuario-Id: ${4:-1}" \
  -H 'X-Scope: catalogo:alta' -d "$3"; }

r=$(alta "alta-cat-sis-001" categorias '{"codigo":"NUEV","nombre":"Categoria Nueva","descripcion":"alta desde API"}' 1)
afirmar "el usuario SISTEMA da de alta" "$(echo "$r" | tail -1)" "201"
afirmar "quedo en la base" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_categorias where codigo='NUEV';")" "1"

for u in 2 3 4; do
  r=$(alta "alta-cat-u$u-0001" categorias '{"codigo":"ZZZA","nombre":"No deberia"}' "$u")
  afirmar "el usuario $u NO puede dar de alta" "$(echo "$r" | tail -1)" "403"
  afirmar "codigo de permiso (usuario $u)" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM020"
done
afirmar "ninguna categoria espuria quedo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_categorias where nombre='No deberia';")" "0"

echo '--- la regla aplica a TODOS los catalogos, no solo a categorias ---'
r=$(alta "alta-alm-u2-0001" almacenes '{"codigo":"ALM-XXX","nombre":"Bodega pirata"}' 2)
afirmar "almacenes: usuario 2 rechazado" "$(echo "$r" | tail -1)" "403"
r=$(alta "alta-cli-u2-0001" clientes '{"nombre":"Cliente pirata"}' 2)
afirmar "clientes: usuario 2 rechazado" "$(echo "$r" | tail -1)" "403"
r=$(alta "alta-usr-u2-0001" usuarios '{"nombre":"Usuario pirata"}' 2)
afirmar "usuarios: usuario 2 rechazado" "$(echo "$r" | tail -1)" "403"
CAT1=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_categorias order by id limit 1;")
r=$(alta "alta-prod-u2-001" productos "{\"categoria_id\":\"$CAT1\",\"nombre\":\"Producto pirata\"}" 2)
afirmar "productos: usuario 2 rechazado" "$(echo "$r" | tail -1)" "403"

echo '--- el usuario 1 si puede en todos ---'
r=$(alta "alta-alm-sis-001" almacenes '{"codigo":"ALM-NVA","nombre":"Bodega Nueva"}' 1)
afirmar "almacenes: SISTEMA autorizado" "$(echo "$r" | tail -1)" "201"
r=$(alta "alta-prod-sis-01" productos "{\"categoria_id\":\"$CAT1\",\"nombre\":\"Producto de alta\",\"precio_unitario\":\"99.50\"}" 1)
afirmar "productos: SISTEMA autorizado" "$(echo "$r" | tail -1)" "201"
afirmar "el SKU lo acuno el motor, no el cliente" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select sku ~ '^[A-Z]{4}-[0-9]{4}\$' from wms.cat_productos where nombre='Producto de alta';")" "t"

echo '--- no se pueden capturar columnas derivadas ---'
r=$(alta "alta-sku-manual-1" productos "{\"categoria_id\":\"$CAT1\",\"nombre\":\"Con SKU\",\"sku\":\"HACK-0001\"}" 1)
afirmar "capturar el SKU a mano se rechaza" "$(echo "$r" | tail -1)" "400"
r=$(alta "alta-cat-mala-01" categorias '{"codigo":"minus","nombre":"Codigo invalido"}' 1)
afirmar "el formato del codigo se valida" "$(echo "$r" | tail -1)" "400"
afirmar "catalogo inexistente" "$(echo "$(alta 'alta-inventado-01' inventado '{"nombre":"x"}' 1)" | tail -1)" "400"

echo '--- la restriccion vive en el MOTOR, no solo en la API ---'
salida=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c \
  "begin; select set_config('wms.ctx_usuario_id','2',true); insert into wms.cat_categorias (codigo,nombre) values ('PIRA','Directo a la base'); commit;" 2>&1 || true)
afirmar "un INSERT directo con otro operador se bloquea" \
  "$(echo "$salida" | grep -c 'WM020\|Solo el usuario SISTEMA')" "1"
afirmar "no quedo el registro" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_categorias where codigo='PIRA';")" "0"

echo '--- idempotencia del alta ---'
r=$(alta "alta-cat-sis-001" categorias '{"codigo":"NUEV","nombre":"Categoria Nueva","descripcion":"alta desde API"}' 1)
afirmar "reenviar la misma alta no duplica" "$(echo "$r" | tail -1)" "201"
afirmar "sigue habiendo una sola" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_categorias where codigo='NUEV';")" "1"

echo
echo '=== 45) LA IMPORTACION TAMPOCO ES UNA VIA DE ESCAPE ==='
mkdir -p "$TMPD"
cat > "$TMPD/alta_pirata.csv" <<'CSV'
categoria_codigo,nombre_producto,descripcion,precio_unitario,estatus,almacen_codigo,cantidad_inicial,cantidad_minima
ELEC,Producto Via Importacion,,50.00,ACTIVO,ALM-NTE,5,1
CSV
r=$(curl -s -w '\n%{http_code}' -X POST "$BASE/api/importacion" \
  -H 'X-Usuario-Id: 3' -F "archivo=@$TMPD/alta_pirata.csv" -F 'modo=SOLO_ALTA')
afirmar "la importacion responde" "$(echo "$r" | tail -1)" "200"
afirmar "el renglon que exigia alta de catalogo se rechaza" \
  "$(campo "$(echo "$r" | head -1)" renglonesOk)" "0"
afirmar "no se creo el producto por la puerta de atras" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_productos where nombre='Producto Via Importacion';")" "0"

echo '--- pero el SISTEMA si puede importar altas ---'
r=$(curl -s -w '\n%{http_code}' -X POST "$BASE/api/importacion" \
  -H 'X-Usuario-Id: 1' -F "archivo=@$TMPD/alta_pirata.csv" -F 'modo=SOLO_ALTA')
afirmar "el SISTEMA importa altas" "$(campo "$(echo "$r" | head -1)" renglonesOk)" "1"
afirmar "el producto quedo creado" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_productos where nombre='Producto Via Importacion';")" "1"

echo
echo '=== 46) CORREGIR UN REGISTRO DE CATALOGO ==='
# La edicion NO exige ser el usuario 1: esa restriccion es del alta y no se
# extiende por simetria. La asimetria esta documentada en la especificacion.
editar() { curl -s -w '\n%{http_code}' -X PUT "$BASE/api/catalogos/$2/$3" \
  -H 'Content-Type: application/json' -H "X-Operation-Id: $1" -H "X-Usuario-Id: ${5:-2}" \
  -H 'X-Scope: catalogo:editar' -d "$4"; }

CLI=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_clientes order by id limit 1;")
VER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_clientes where id=$CLI;")

r=$(editar "edit-cli-0001" clientes "$CLI" "{\"campos\":{\"telefono\":\"55-1234-5678\"},\"versionEsperada\":$VER}" 2)
afirmar "un operador cualquiera puede corregir" "$(echo "$r" | tail -1)" "200"
afirmar "el telefono quedo guardado" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select telefono from wms.cat_clientes where id=$CLI;")" "55-1234-5678"
afirmar "la version se incremento" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_clientes where id=$CLI;")" "$((VER+1))"

echo '--- la version vieja ya no sirve: nadie pisa el cambio de otro ---'
r=$(editar "edit-cli-0002" clientes "$CLI" "{\"campos\":{\"telefono\":\"55-0000-0000\"},\"versionEsperada\":$VER}" 3)
afirmar "version obsoleta rechazada" "$(echo "$r" | tail -1)" "409"
afirmar "codigo de concurrencia" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM008"
afirmar "el telefono NO se piso" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select telefono from wms.cat_clientes where id=$CLI;")" "55-1234-5678"

echo '--- la version es obligatoria ---'
afirmar "sin versionEsperada" \
  "$(echo "$(editar "edit-sin-ver-001" clientes "$CLI" '{"campos":{"telefono":"55-9"}}' 2)" | tail -1)" "400"

echo '--- un registro inexistente da 404, no 409 ---'
afirmar "id inexistente" \
  "$(echo "$(editar "edit-inexist-001" clientes 999999 '{"campos":{"telefono":"55-9"},"versionEsperada":1}' 2)" | tail -1)" "404"

echo '--- las columnas derivadas no se pueden escribir ---'
VER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_clientes where id=$CLI;")
afirmar "codigo generado rechazado" \
  "$(echo "$(editar "edit-cod-0001" clientes "$CLI" "{\"campos\":{\"codigo\":\"CLI-9999\"},\"versionEsperada\":$VER}" 2)" | tail -1)" "400"
afirmar "sello de baja rechazado" \
  "$(echo "$(editar "edit-sello-001" clientes "$CLI" "{\"campos\":{\"desactivado_en\":\"2020-01-01\"},\"versionEsperada\":$VER}" 2)" | tail -1)" "400"
afirmar "version de concurrencia rechazada como campo" \
  "$(echo "$(editar "edit-verc-0001" clientes "$CLI" "{\"campos\":{\"version_concurrencia\":\"99\"},\"versionEsperada\":$VER}" 2)" | tail -1)" "400"
afirmar "un obligatorio no se puede vaciar" \
  "$(echo "$(editar "edit-vacio-001" clientes "$CLI" "{\"campos\":{\"nombre\":\"\"},\"versionEsperada\":$VER}" 2)" | tail -1)" "400"

echo '--- reenviar la MISMA correccion es un reintento, no un segundo cambio ---'
VER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_clientes where id=$CLI;")
r1=$(editar "edit-idem-0001" clientes "$CLI" "{\"campos\":{\"telefono\":\"55-7777-7777\"},\"versionEsperada\":$VER}" 2)
r2=$(editar "edit-idem-0001" clientes "$CLI" "{\"campos\":{\"telefono\":\"55-7777-7777\"},\"versionEsperada\":$VER}" 2)
afirmar "el reenvio responde igual" "$(echo "$r2" | tail -1)" "$(echo "$r1" | tail -1)"
afirmar "la version solo subio una vez" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_clientes where id=$CLI;")" "$((VER+1))"

echo
echo '=== 47) EL ROL NO ES UNA VIA DE ASCENSO ==='
# PermisoExportacion autoriza por ROL. Si la edicion dejara tocar el rol,
# un OPERADOR se concederia la exportacion con precios y valuacion.
#
# El sujeto es el usuario 3: en la semilla el 2 ya es SUPERVISOR, y pedir
# que suba a SUPERVISOR seria una asignacion sin cambio que el trigger, con
# razon, ni siquiera mira.
OPER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_usuarios where rol='OPERADOR' order by id limit 1;")
afirmar "el sujeto de la prueba es OPERADOR" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select rol from wms.cat_usuarios where id=$OPER;")" "OPERADOR"
afirmar "y hoy no puede exportar" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/exportar" -H "X-Usuario-Id: $OPER")" "403"

UVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_usuarios where id=$OPER;")
r=$(editar "edit-rol-op-001" usuarios "$OPER" "{\"campos\":{\"rol\":\"SUPERVISOR\"},\"versionEsperada\":$UVER}" "$OPER")
afirmar "un operador NO se asciende solo" "$(echo "$r" | tail -1)" "403"
afirmar "codigo de rol" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM021"
afirmar "el rol siguio igual" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select rol from wms.cat_usuarios where id=$OPER;")" "OPERADOR"
afirmar "y por tanto sigue sin poder exportar" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/exportar" -H "X-Usuario-Id: $OPER")" "403"

echo '--- tampoco puede ascender a un tercero ---'
OTRO=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_usuarios where rol='OPERADOR' and id<>$OPER order by id limit 1;")
OVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_usuarios where id=$OTRO;")
afirmar "ascender a otro tambien se rechaza" \
  "$(echo "$(editar "edit-rol-otro-01" usuarios "$OTRO" "{\"campos\":{\"rol\":\"SUPERVISOR\"},\"versionEsperada\":$OVER}" "$OPER")" | tail -1)" "403"

echo '--- el resto del mismo registro si lo corrige cualquiera ---'
UVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_usuarios where id=$OPER;")
afirmar "corregir el nombre del operador" \
  "$(echo "$(editar "edit-nom-op-001" usuarios "$OPER" "{\"campos\":{\"nombre\":\"Operador Corregido\"},\"versionEsperada\":$UVER}" "$OPER")" | tail -1)" "200"

echo '--- el rol del propio operador SISTEMA es fijo, incluso para el ---'
SVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_usuarios where id=1;")
r=$(editar "edit-rol-sis-fij" usuarios 1 "{\"campos\":{\"rol\":\"OPERADOR\"},\"versionEsperada\":$SVER}" 1)
afirmar "el SISTEMA no se degrada" "$(echo "$r" | tail -1)" "403"
afirmar "sigue siendo SISTEMA" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select rol from wms.cat_usuarios where id=1;")" "SISTEMA"

echo '--- el operador 1 si puede ascender a otro ---'
UVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_usuarios where id=$OPER;")
afirmar "el SISTEMA cambia el rol" \
  "$(echo "$(editar "edit-rol-sis-001" usuarios "$OPER" "{\"campos\":{\"rol\":\"SUPERVISOR\"},\"versionEsperada\":$UVER}" 1)" | tail -1)" "200"
afirmar "ahora si exporta" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inventario/exportar" -H "X-Usuario-Id: $OPER")" "200"
echo
echo '=== 48) EL PREFIJO ACUNADO SIGUE CONGELADO ==='
# La categoria que la semilla ya uso para acunar SKUs no puede cambiar de
# codigo: lo impide la FK sku_prefijo -> codigo, no la API.
CVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_categorias where id=$CAT1;")
r=$(editar "edit-cat-cod-01" categorias "$CAT1" "{\"campos\":{\"codigo\":\"XXXX\"},\"versionEsperada\":$CVER}" 2)
afirmar "codigo con SKU acunado rechazado" "$(echo "$r" | tail -1)" "409"
afirmar "lo rechaza la integridad referencial" "$(campo "$(echo "$r" | head -1)" codigoWms)" "23503"

echo '--- una categoria sin productos si se corrige ---'
NUEVA=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_categorias where codigo='NUEV';")
NVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_categorias where id=$NUEVA;")
afirmar "codigo sin acunar corregido" \
  "$(echo "$(editar "edit-cat-cod-02" categorias "$NUEVA" "{\"campos\":{\"codigo\":\"NUVA\"},\"versionEsperada\":$NVER}" 2)" | tail -1)" "200"

echo '--- recategorizar un producto NO reescribe su SKU ---'
PROD1=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_productos order by id limit 1;")
SKU1=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select sku from wms.cat_productos where id=$PROD1;")
PVER=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select version_concurrencia from wms.cat_productos where id=$PROD1;")
NUEVA=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_categorias where codigo='NUVA';")
afirmar "recategorizar acepta" \
  "$(echo "$(editar "edit-prod-cat-1" productos "$PROD1" "{\"campos\":{\"categoria_id\":\"$NUEVA\"},\"versionEsperada\":$PVER}" 2)" | tail -1)" "200"
afirmar "el SKU no cambio" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select sku from wms.cat_productos where id=$PROD1;")" "$SKU1"

echo
echo '=== 49) BAJA LOGICA Y REACTIVACION ==='
vigencia() { curl -s -w '\n%{http_code}' -X POST "$BASE/api/catalogos/$2/$3/$4" \
  -H "X-Operation-Id: $1" -H "X-Usuario-Id: ${5:-2}" -H "X-Scope: catalogo:$4"; }

CLI2=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_clientes order by id desc limit 1;")
r=$(vigencia "baja-cli-0001" clientes "$CLI2" desactivar 3)
afirmar "la baja logica aplica" "$(echo "$r" | tail -1)" "200"
afirmar "el registro sigue existiendo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select count(*) from wms.cat_clientes where id=$CLI2;")" "1"
afirmar "quedo sellada con el autor" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select desactivado_por_usuario_id from wms.cat_clientes where id=$CLI2;")" "3"
afirmar "y con la fecha" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select desactivado_en is not null from wms.cat_clientes where id=$CLI2;")" "t"

echo '--- desactivar dos veces avisa en vez de fingir que hizo algo ---'
r=$(vigencia "baja-cli-0002" clientes "$CLI2" desactivar 3)
afirmar "segunda baja rechazada" "$(echo "$r" | tail -1)" "409"
afirmar "codigo de vigencia" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM023"

echo '--- el listado vigente ya no lo ofrece, el completo si ---'
afirmar "fuera del listado vigente" \
  "$(curl -s "$BASE/api/catalogos/clientes?porPagina=200" | grep -o "\"id\":$CLI2," | wc -l | tr -d ' ')" "0"
afirmar "presente en el listado completo" \
  "$(curl -s "$BASE/api/catalogos/clientes?soloVigentes=false&porPagina=200" | grep -o "\"id\":$CLI2," | wc -l | tr -d ' ')" "1"

echo '--- reactivar conserva el rastro de la baja ---'
r=$(vigencia "alta-cli-r0001" clientes "$CLI2" reactivar 2)
afirmar "la reactivacion aplica" "$(echo "$r" | tail -1)" "200"
afirmar "el sello de la baja anterior sobrevive" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select desactivado_por_usuario_id from wms.cat_clientes where id=$CLI2;")" "3"

echo '--- la baja exige operador declarado ---'
afirmar "sin X-Usuario-Id" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/catalogos/clientes/$CLI2/desactivar" -H 'X-Operation-Id: baja-sin-usr-01')" "422"

echo '--- el operador SISTEMA no se puede desactivar ---'
r=$(vigencia "baja-sistema-01" usuarios 1 desactivar 1)
afirmar "la baja del SISTEMA se rechaza" "$(echo "$r" | tail -1)" "409"
afirmar "codigo de proteccion" "$(campo "$(echo "$r" | head -1)" codigoWms)" "WM022"
afirmar "el SISTEMA sigue activo" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select es_activo from wms.cat_usuarios where id=1;")" "t"
afirmar "y sigue pudiendo dar de alta" \
  "$(echo "$(alta "alta-post-baja01" clientes '{"nombre":"Cliente tras el intento"}' 1)" | tail -1)" "201"

echo '--- un producto se da de baja por estatus, no por es_activo ---'
PROD2=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_productos order by id desc limit 1;")
afirmar "baja de producto" \
  "$(echo "$(vigencia "baja-prod-0001" productos "$PROD2" desactivar 2)" | tail -1)" "200"
afirmar "el estatus quedo INACTIVO" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select estatus from wms.cat_productos where id=$PROD2;")" "INACTIVO"
afirmar "con su sello de autor" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select desactivado_por_usuario_id from wms.cat_productos where id=$PROD2;")" "2"

echo '--- reenviar la misma baja es un reintento ---'
PROD3=$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select id from wms.cat_productos where estatus='ACTIVO' order by id desc limit 1;")
r1=$(vigencia "baja-idem-0001" productos "$PROD3" desactivar 2)
r2=$(vigencia "baja-idem-0001" productos "$PROD3" desactivar 2)
afirmar "el reenvio responde igual" "$(echo "$r2" | tail -1)" "$(echo "$r1" | tail -1)"
afirmar "una sola baja registrada" "$(echo "$r2" | tail -1)" "200"

echo '--- un catalogo desconocido no se edita ni se da de baja ---'
afirmar "recurso inexistente en PUT" \
  "$(echo "$(editar "edit-desconoc-01" movimientos 1 '{"campos":{"x":"1"},"versionEsperada":1}' 2)" | tail -1)" "400"
afirmar "recurso inexistente en baja" \
  "$(echo "$(vigencia "baja-desconoc-1" movimientos 1 desactivar 2)" | tail -1)" "400"

echo '=== 10) INVARIANTE FINAL ==='
afirmar "sum(delta_fisica) = cantidad_fisica en todo el inventario" \
  "$(docker exec "$PG" psql -U postgres -d wms -qtAX -c "select bool_and(ok) from (select i.cantidad_fisica = coalesce((select sum(m.delta_fisica) from wms.tbl_movimientos_inventario m where m.producto_id=i.producto_id and m.almacen_id=i.almacen_id),0) as ok from wms.tbl_inventario i) t;")" "t"

echo
if [ "$fallos" -gt 0 ]; then echo; echo '--- ultimos errores de la API ---'; docker logs "$API" 2>&1 | grep -iE 'exception|fail' | tail -12; fi
if [ "$fallos" -eq 0 ]; then echo "=== API E2E: TODAS LAS PRUEBAS PASARON ==="; exit 0
else echo "=== API E2E: $fallos FALLO(S) ==="; exit 1; fi
