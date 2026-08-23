# Mini WMS + Órdenes

Sistema de inventario y órdenes de salida: catálogo de productos con SKU acuñado por el
motor, existencias por almacén, órdenes con reserva y embarque, importación masiva y
bitácora de movimientos de sólo inserción.

**.NET 8** (Minimal API · CQRS con MediatR · Dapper · Polly) · **React 18 + TypeScript**
(Vite · Tailwind · TanStack Query) · **PostgreSQL 16**.

---

## Arrancar

Sólo hace falta Docker.

```bash
docker compose up -d --build
```

Eso levanta cuatro servicios en orden: PostgreSQL, un **migrador** que aplica el esquema y
la semilla y termina, la API y el frontend. La API no arranca hasta que el migrador sale
con éxito, así que si una migración falla no queda una aplicación a medio camino.

| | URL |
|---|---|
| Aplicación | <http://localhost:5174> |
| API | <http://localhost:8081> |
| Sonda | <http://localhost:8081/api/salud> |

Los puertos se cambian con `PUERTO_WEB` y `PUERTO_API`:

```bash
PUERTO_WEB=3000 PUERTO_API=5000 docker compose up -d
```

Para empezar de cero —esquema y datos— hay que borrar el volumen:

```bash
docker compose down -v && docker compose up -d --build
```

`docker compose up` es **re-ejecutable**: el migrador lleva un registro de lo ya aplicado,
así que volver a levantar sobre un volumen existente no intenta recrear nada.

---

## Qué hay dentro

```
db/migraciones/     Esquema, lógica en PL/pgSQL, permisos. Se aplican en orden.
db/semilla.sql      Datos de demostración: 5 operadores, 6 categorías, 40 productos, 10 órdenes.
db/pruebas/         Verificación del motor: 5 suites sobre un PostgreSQL desechable.
src/Wms.Domain/     Errores de negocio y su mapeo a HTTP. Sin dependencias.
src/Wms.Application/  Un directorio por caso de uso (vertical slice) + protocolo de operación.
src/Wms.Infrastructure/  Dapper, Npgsql, Polly.
src/Wms.Api/        Minimal API, middleware de errores, barrido de operaciones colgadas.
tests/Wms.UnitTests/  xUnit + FluentAssertions.
tests/verificar_api.sh  Verificación extremo a extremo sobre HTTP, con curl.
web/                Frontend. `web/e2e/` son las pruebas de navegador (Playwright).
docs/superpowers/specs/  La especificación de diseño, con el porqué de cada decisión.
transcript/         El historial de la conversación que definió el proyecto.
```

---

## Cómo se usa

En la barra lateral se elige el **operador activo**. No hay autenticación —queda fuera del
alcance—, pero sí **atribución**: toda mutación viaja con su operador y la API rechaza
cualquiera que llegue sin él. Cambiar de operador invalida las intenciones en vuelo.

Un recorrido completo:

1. **Catálogos** → *Nuevo* para dar de alta una categoría y un almacén.
   El botón sólo aparece para el operador **Sistema**: el alta en catálogos está reservada
   al usuario 1, y la restricción vive en la base de datos, no en el botón.
2. **Importación** → descargar la plantilla, capturar productos con su existencia inicial y
   subirla. El SKU **no** va en la plantilla: lo acuña el servidor. Reimportar el mismo
   archivo no duplica nada.
3. **Inventario** → las existencias por producto y almacén. Los controles `+`/`−` aplican de
   inmediato; *Ajustar* abre el conteo físico a cantidad absoluta. *Exportar* genera un CSV
   con **todo** el conjunto filtrado, no sólo la página visible (limitado a SUPERVISOR y
   SISTEMA porque incluye precios y valuación).
4. **Órdenes** → *Nueva orden*, elegir cliente, almacén y partidas.
   **Confirmar** reserva sin tocar la existencia física. **Enviar** descuenta y libera la
   reserva. **Cancelar** devuelve lo reservado.
5. **Movimientos** → la bitácora, con su autor, su hora y su identificador de operación.
   Un clic selecciona, doble clic abre el detalle. Desactivar un movimiento está reservado
   al operador Sistema y **no borra**: asienta un renglón contrario.
6. **Tablero** → indicadores, serie de embarques, productos de mayor demanda y existencia
   insuficiente.

---

## Las tres cosas que conviene saber antes de leer el código

**El SKU se acuña y se congela.** `ELEC-0001` no se deriva de la categoría vigente: el
prefijo y el consecutivo se copian al crear el producto y se guardan. Recategorizar un
producto no reescribe su SKU, y cambiar el código de una categoría que ya acuñó productos
lo impide una clave foránea. Un identificador que cambia deja de identificar.

**La idempotencia es por INTENCIÓN, no por petición.** El cliente acuña un `id_operacion`
al *formar* la intención —al abrir el modal, no al pulsar— y lo reenvía idéntico en cada
reintento. Hay dos barreras: la tabla de operaciones y un índice único sobre la bitácora
que escribe un trigger dentro de la misma transacción que mueve la existencia. Si el índice
salta, la existencia se revierte con él. Cancelar una petición desde el navegador es
ahorro de tráfico, nunca una garantía: lo que ya se confirmó, confirmado está.

**La bitácora es de sólo inserción.** No se actualiza ni se borra: los triggers lo impiden y
el rol de la aplicación no tiene permiso de `INSERT` directo sobre ella. «Desactivar» un
movimiento asienta el movimiento contrario, como una póliza de reversa. Por eso revertir
una entrada de +10 de la que ya se consumieron 3 se **rechaza**: dejaría la existencia en
−3, y la contabilidad no admite existencias negativas.

---

## Pruebas

Las cuatro suites corren contra PostgreSQL 16 y .NET 8 reales, en contenedores
desechables. No hay dobles ni motores en memoria.

```bash
# Motor: esquema, triggers, concurrencia real con sesiones paralelas.
bash db/pruebas/verificar.sh                    # 5 suites, 58 aserciones

# Unitarias del backend.
docker run --rm -v "$PWD":/w -w /w mcr.microsoft.com/dotnet/sdk:8.0 \
  dotnet test tests/Wms.UnitTests                # 83 pruebas

# API extremo a extremo sobre HTTP: levanta su propia pila y la ejerce con curl.
bash tests/verificar_api.sh                     # 279 aserciones

# Componentes del frontend.
cd web && npm test                              # 47 pruebas

# Navegador, contra la pila levantada con docker compose.
cd web && npx playwright install chromium && npm run e2e   # 10 escenarios
```

`verificar_api.sh` es la única forma de cerrar los casos que la suite SQL no alcanza:
reintento tras *timeout*, latencia real y cancelación del cliente a mitad de transacción.
Playwright cubre lo que sólo se ve en un navegador: el modal bajo latencia, dos pestañas
con operadores distintos sobre el mismo producto, y que ocultar un botón no autoriza nada.

---

## Notas de operación

**El barrido de operaciones colgadas.** Si un proceso muere entre reservar una operación y
ejecutarla, su identificador quedaría bloqueado. La migración `0003` programa el barrido
con `pg_cron` cuando la extensión está disponible; la imagen `postgres:16-alpine` no la
trae, así que la API hospeda ese barrido como servicio en segundo plano, una vez por
minuto. Es una red de último recurso: el camino normal es que la propia petición cierre su
operación al fallar.

**Paginación.** Todos los listados van de 25 en 25, recortados en el motor. La exportación
NO se pagina: lleva los filtros de la pantalla y ningún parámetro de página. `porPagina` se
acota a 200; pedir más devuelve 200, no la tabla entera.

**Qué queda fuera del alcance, por decisión declarada:** autenticación de usuarios y
Row Level Security. `cat_usuarios` es un registro de operadores sin credenciales, y existe
para poder auditar sin construir un sistema de identidad.

---

## Documentación

- [`docs/superpowers/specs/2026-08-21-mini-wms-ordenes-design.md`](docs/superpowers/specs/2026-08-21-mini-wms-ordenes-design.md)
  — el diseño completo: esquema, decisiones, auditorías, los diez escenarios de
  concurrencia y la matriz de pruebas.
- [`AI-USAGE.md`](AI-USAGE.md) — cómo se usó la asistencia de IA durante la prueba.
- [`transcript/`](transcript/) — el historial de la conversación que definió el proyecto,
  extraído literalmente del registro de la sesión y ordenado cronológicamente.
