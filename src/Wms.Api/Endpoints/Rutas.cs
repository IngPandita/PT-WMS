using FluentValidation;
using MediatR;
using Wms.Application.Abstracciones;
using Wms.Application.Consultas;
using Wms.Application.Inventario.AjustarExistencia;
using Wms.Application.Inventario.ConsultarMovimientos;
using Wms.Application.Inventario.ConsultarTablero;
using Wms.Application.Catalogos;
using Wms.Application.Importacion;
using Wms.Application.Inventario.EstablecerExistencia;
using Wms.Application.Inventario.Exportar;
using Wms.Application.Movimientos;
using Wms.Domain.Errores;
using Wms.Application.Ordenes;

namespace Wms.Api.Endpoints;

public static class Rutas
{
    public static void Mapear(WebApplication app)
    {
        app.MapGet("/api/salud", () => Results.Ok(new { estado = "ok" }));

        MapearInventario(app);
        MapearOrdenes(app);
        MapearImportacion(app);
        MapearCatalogos(app);
        MapearProductos(app);
        MapearAltaCatalogo(app);
        MapearSku(app);
        MapearIndicadores(app);
    }

    private static void MapearInventario(WebApplication app)
    {
        app.MapGet("/api/inventario", async (IMediator m, long? almacenId, string? q,
            bool? soloExistenciaBaja, int? pagina, int? porPagina, CancellationToken ct) =>
            Results.Ok(await m.Send(new ConsultaTablero(
                almacenId, q, soloExistenciaBaja ?? false, pagina, porPagina), ct)));

        // Exportacion: el CSV se escribe DIRECTO al flujo de respuesta conforme
        // el motor entrega las filas. Ni la API ni el navegador materializan el
        // catalogo completo.
        app.MapGet("/api/inventario/exportar", async (
            HttpContext http, ExportadorInventario exportador, IFabricaConexion fabrica,
            long? almacenId, string? q, bool? soloExistenciaBaja, CancellationToken ct) =>
        {
            if (!long.TryParse(http.Request.Headers["X-Usuario-Id"], out var usuarioId) || usuarioId <= 0)
                throw new ExcepcionWms("WM014", 422, "Falta el encabezado X-Usuario-Id.",
                    "La exportacion se atribuye a un operador.");

            await using (var conexion = await fabrica.AbrirAsync(ct))
                await PermisoExportacion.ExigirAsync(conexion, usuarioId, ct);

            var nombre = $"inventario-{DateTime.UtcNow:yyyyMMdd-HHmm}.csv";
            http.Response.ContentType = "text/csv; charset=utf-8";
            http.Response.Headers.ContentDisposition = $"attachment; filename=\"{nombre}\"";

            await exportador.EscribirCsvAsync(http.Response.Body,
                new FiltroExportacion(almacenId, q, soloExistenciaBaja ?? false), ct);
            return Results.Empty;
        });

        app.MapGet("/api/inventario/movimientos", async (IMediator m, long? productoId,
            long? almacenId, long? usuarioId, string? sku, string? idOperacion,
            DateTime? desde, DateTime? hasta, string? tipo, int? pagina, int? porPagina,
            CancellationToken ct) =>
            Results.Ok(await m.Send(new ConsultaMovimientos(
                productoId, almacenId, usuarioId, sku, idOperacion,
                desde, hasta, tipo, pagina, porPagina), ct)));

        app.MapGet("/api/inventario/movimientos/{id:long}", async (IMediator m, long id, CancellationToken ct) =>
        {
            var r = await m.Send(new ConsultaDetalleMovimiento(id), ct);
            return r is null ? Results.NotFound(new { title = "Movimiento inexistente", status = 404 })
                             : Results.Ok(r);
        });

        // Desactivacion de un movimiento. La restriccion a usuario 1 la impone
        // fn_revertir_movimiento en el MOTOR: esta capa solo la traduce a HTTP.
        app.MapPost("/api/inventario/movimientos/{id:long}/desactivar", async (IMediator m,
            IValidator<ComandoRevertirMovimiento> v, long id, CuerpoMotivo cuerpo,
            CancellationToken ct) =>
        {
            var cmd = new ComandoRevertirMovimiento(id, cuerpo.Motivo);
            await v.ValidateAndThrowAsync(cmd, ct);
            return Results.Ok(await m.Send(cmd, ct));
        });

        app.MapPost("/api/inventario/ajustar", async (IMediator m,
            IValidator<ComandoAjustarExistencia> v, ComandoAjustarExistencia cmd, CancellationToken ct) =>
        {
            await v.ValidateAndThrowAsync(cmd, ct);
            return Results.Ok(await m.Send(cmd, ct));
        });

        // Ajuste manual a cantidad OBJETIVO. La conversion objetivo->delta la
        // hace la base bajo el row lock, no el cliente.
        app.MapPost("/api/inventario/establecer", async (IMediator m,
            IValidator<ComandoEstablecerExistencia> v, ComandoEstablecerExistencia cmd,
            CancellationToken ct) =>
        {
            await v.ValidateAndThrowAsync(cmd, ct);
            return Results.Ok(await m.Send(cmd, ct));
        });
    }

    private static void MapearOrdenes(WebApplication app)
    {
        app.MapGet("/api/ordenes", async (IMediator m, string? estatus, long? clienteId,
            long? almacenId, int? pagina, int? porPagina, CancellationToken ct) =>
            Results.Ok(await m.Send(new ConsultaOrdenes(estatus, clienteId, almacenId, pagina, porPagina), ct)));

        app.MapGet("/api/ordenes/{id:long}/partidas", async (IMediator m, long id, CancellationToken ct) =>
            Results.Ok(await m.Send(new ConsultaPartidas(id), ct)));

        app.MapPost("/api/ordenes", async (IMediator m, IValidator<ComandoCrearOrden> v,
            ComandoCrearOrden cmd, CancellationToken ct) =>
        {
            await v.ValidateAndThrowAsync(cmd, ct);
            var r = await m.Send(cmd, ct);
            // 201 en el alta; 200 si fue un reenvio de una orden ya creada.
            return r.FueReenvio ? Results.Ok(r) : Results.Created($"/api/ordenes/{r.Id}", r);
        });

        app.MapPost("/api/ordenes/{id:long}/confirmar", async (IMediator m, long id, CancellationToken ct) =>
            Results.Ok(await m.Send(new ComandoConfirmarOrden(id), ct)));

        app.MapPost("/api/ordenes/{id:long}/enviar", async (IMediator m, long id, CancellationToken ct) =>
            Results.Ok(await m.Send(new ComandoEnviarOrden(id), ct)));

        app.MapPost("/api/ordenes/{id:long}/cancelar", async (IMediator m,
            IValidator<ComandoCancelarOrden> v, long id, CuerpoCancelacion cuerpo, CancellationToken ct) =>
        {
            var cmd = new ComandoCancelarOrden(id, cuerpo.Motivo);
            await v.ValidateAndThrowAsync(cmd, ct);
            return Results.Ok(await m.Send(cmd, ct));
        });
    }

    private static void MapearImportacion(WebApplication app)
    {
        app.MapGet("/api/importacion/plantilla", () =>
            Results.File(Plantilla.GenerarCsv(), "text/csv; charset=utf-8", "plantilla-wms.csv"));

        app.MapPost("/api/importacion", async (IMediator m, HttpRequest req, CancellationToken ct) =>
        {
            if (!req.HasFormContentType)
                return Results.BadRequest(new { title = "Se espera multipart/form-data con el campo 'archivo'.", status = 400 });

            var form = await req.ReadFormAsync(ct);
            var archivo = form.Files["archivo"];
            if (archivo is null || archivo.Length == 0)
                return Results.BadRequest(new { title = "Falta el archivo o viene vacio.", status = 400 });
            if (archivo.Length > 5 * 1024 * 1024)
                return Results.BadRequest(new { title = "El archivo excede 5 MB.", status = 400 });

            using var ms = new MemoryStream();
            await archivo.CopyToAsync(ms, ct);

            var modo = form["modo"].ToString();
            var r = await m.Send(new ComandoImportar(archivo.FileName, ms.ToArray(), modo), ct);
            return Results.Ok(r);
        }).DisableAntiforgery();

        // Los renglones del lote son un listado mas: van paginados.
        app.MapGet("/api/importacion/{id:long}", async (IMediator m, long id,
            int? pagina, int? porPagina, CancellationToken ct) =>
        {
            var r = await m.Send(new ConsultaResultadoImportacion(id, pagina, porPagina), ct);
            return r is null ? Results.NotFound(new { title = "Lote inexistente", status = 404 }) : Results.Ok(r);
        });
    }

    private static void MapearCatalogos(WebApplication app) =>
        app.MapGet("/api/catalogos/{recurso}", async (IMediator m, string recurso,
            bool? soloVigentes, int? pagina, int? porPagina, CancellationToken ct) =>
        {
            try
            {
                return Results.Ok(await m.Send(
                    new ConsultaCatalogo(recurso, soloVigentes ?? true, pagina, porPagina), ct));
            }
            catch (KeyNotFoundException ex)
            {
                return Results.NotFound(new { title = ex.Message, status = 404 });
            }
        });

    private static void MapearProductos(WebApplication app) =>
        app.MapGet("/api/productos/buscar", async (IMediator m, string q, long? almacenId,
            int? limite, CancellationToken ct) =>
            Results.Ok(await m.Send(new ConsultaBuscarProductos(q ?? string.Empty, almacenId, limite ?? 20), ct)));

    // Alta en catalogos. La restriccion a usuario 1 la impone tambien el
    // trigger a_trg_cat_*__alta_solo_sistema, asi que llamar aqui directo con
    // otro operador no sirve de nada.
    private static void MapearAltaCatalogo(WebApplication app)
    {
        app.MapPost("/api/catalogos/{recurso}", async (IMediator m, HttpContext http,
            IValidator<ComandoAltaCatalogo> v, string recurso,
            Dictionary<string, string?> campos, CancellationToken ct) =>
        {
            // El permiso se evalua ANTES de validar el cuerpo: a un operador sin
            // autorizacion se le responde 403, no 400 por un campo mal escrito.
            if (http.Request.Headers["X-Usuario-Id"].ToString() != "1")
                throw new ExcepcionWms("WM020", 403,
                    "Solo el usuario SISTEMA puede dar de alta registros en catálogos.",
                    "La restricción también vive en la base de datos: llamar al endpoint " +
                    "directamente con otro operador tampoco funciona.");

            var cmd = new ComandoAltaCatalogo(recurso, campos ?? new());
            await v.ValidateAndThrowAsync(cmd, ct);
            var fila = await m.Send(cmd, ct);
            return Results.Created($"/api/catalogos/{recurso}", fila);
        });

        // Correccion de un registro existente. NO exige ser el operador 1: esa
        // restriccion es del ALTA y no se extiende por simetria. La asimetria
        // esta documentada en la especificacion (3.11).
        //
        // La version esperada es obligatoria y viaja en el cuerpo, no en
        // If-Match: el resto de la API ya la lleva asi (versionEsperada del
        // ajuste), y mezclar dos convenciones para lo mismo confunde mas de lo
        // que ahorra.
        app.MapPut("/api/catalogos/{recurso}/{id:long}", async (IMediator m,
            IValidator<ComandoEditarCatalogo> v, string recurso, long id,
            CuerpoEdicionCatalogo cuerpo, CancellationToken ct) =>
        {
            var cmd = new ComandoEditarCatalogo(
                recurso, id, cuerpo.Campos ?? new(), cuerpo.VersionEsperada);
            await v.ValidateAndThrowAsync(cmd, ct);
            return Results.Ok(await m.Send(cmd, ct));
        });

        // Baja logica y su reverso. Nunca borra: fn_sellar_baja_logica estampa
        // quien y cuando, y reactivar no limpia ese sello.
        app.MapPost("/api/catalogos/{recurso}/{id:long}/desactivar", async (IMediator m,
            IValidator<ComandoCambiarVigenciaCatalogo> v, string recurso, long id,
            CancellationToken ct) =>
        {
            var cmd = new ComandoCambiarVigenciaCatalogo(recurso, id, false);
            await v.ValidateAndThrowAsync(cmd, ct);
            return Results.Ok(await m.Send(cmd, ct));
        });

        app.MapPost("/api/catalogos/{recurso}/{id:long}/reactivar", async (IMediator m,
            IValidator<ComandoCambiarVigenciaCatalogo> v, string recurso, long id,
            CancellationToken ct) =>
        {
            var cmd = new ComandoCambiarVigenciaCatalogo(recurso, id, true);
            await v.ValidateAndThrowAsync(cmd, ct);
            return Results.Ok(await m.Send(cmd, ct));
        });
    }

    private static void MapearSku(WebApplication app) =>
        app.MapGet("/api/sku/analizar", async (IRepositorioReglasSku repo, string sku, CancellationToken ct) =>
        {
            var analizador = await repo.ObtenerAnalizadorAsync(ct);
            var r = analizador.Analizar(sku);
            return r.EsValido
                ? Results.Ok(new { valido = true, prefijo = r.Prefijo, consecutivo = r.Consecutivo,
                    regla = analizador.Regla.Nombre, patron = analizador.Regla.PatronCompleto })
                : Results.UnprocessableEntity(new { valido = false, motivo = r.Motivo,
                    regla = analizador.Regla.Nombre, patron = analizador.Regla.PatronCompleto });
        });

    private static void MapearIndicadores(WebApplication app) =>
        app.MapGet("/api/indicadores", async (IMediator m, int? dias, int? topN, CancellationToken ct) =>
            Results.Ok(await m.Send(new ConsultaIndicadores(dias ?? 30, topN ?? 10), ct)));
}

public sealed record CuerpoCancelacion(string Motivo);
public sealed record CuerpoMotivo(string Motivo);

public sealed record CuerpoEdicionCatalogo(Dictionary<string, string?> Campos, long VersionEsperada);
