using System.Text.Json;
using FluentValidation;
using Npgsql;
using Wms.Domain.Errores;

namespace Wms.Api.Middleware;

/// <summary>
/// Único punto donde un error se convierte en HTTP. Traduce por SQLSTATE,
/// nunca por el texto del mensaje: los mensajes están en español y cambiarlos
/// no debe alterar el contrato de la API.
/// </summary>
public sealed class ManejadorExcepciones(RequestDelegate siguiente, ILogger<ManejadorExcepciones> log)
{
    public async Task InvokeAsync(HttpContext ctx)
    {
        try
        {
            await siguiente(ctx);
        }
        catch (Exception ex)
        {
            var (estado, codigo, titulo, detalle) = Traducir(ex, ctx);

            if (estado >= 500)
                log.LogError(ex, "Fallo no controlado en {Ruta}", ctx.Request.Path);
            else
                log.LogInformation("{Codigo} en {Ruta}: {Mensaje}", codigo, ctx.Request.Path, ex.Message);

            if (ctx.Response.HasStarted) return;

            ctx.Response.Clear();
            ctx.Response.StatusCode = estado;
            ctx.Response.ContentType = "application/problem+json";

            if (codigo is "WM013") ctx.Response.Headers.RetryAfter = "1";

            await ctx.Response.WriteAsync(JsonSerializer.Serialize(new
            {
                type = $"https://wms.local/errores/{codigo}",
                title = titulo,
                status = estado,
                detail = detalle,
                instance = ctx.Request.Path.Value,
                codigoWms = codigo
            }));
        }
    }

    private static (int, string, string, string) Traducir(Exception ex, HttpContext ctx) => ex switch
    {
        ExcepcionWms w => (w.Http, w.Codigo, w.Message, w.Detalle ?? w.Message),

        ValidationException v => (400, "VALIDACION", "La petición no es válida",
            string.Join(" ", v.Errors.Select(e => e.ErrorMessage))),

        // El cuerpo no liga con el contrato: un decimal donde va un entero, un
        // campo con el tipo equivocado, JSON mal formado. Es error del cliente,
        // no del servidor, y sin esta rama caía en el 500 genérico.
        BadHttpRequestException b => (400, "CUERPO_INVALIDO",
            "El cuerpo de la petición no es válido", b.Message),

        System.Text.Json.JsonException j => (400, "CUERPO_INVALIDO",
            "El cuerpo de la petición no es JSON válido", j.Message),

        PostgresException p => TraducirPostgres(p),

        // El cliente cortó. Nada se aplicó: la transacción hizo ROLLBACK.
        OperationCanceledException when ctx.RequestAborted.IsCancellationRequested =>
            (499, "57014", "Petición cancelada por el cliente",
             "La transacción se revirtió; no se aplicó ningún cambio."),

        _ => (500, "INTERNO", "Error interno", "Ocurrió un error no previsto.")
    };

    private static (int, string, string, string) TraducirPostgres(PostgresException p)
    {
        var def = CodigoWms.Resolver(p.SqlState);

        // La violación del índice de idempotencia no es un fallo: es la barrera
        // del motor impidiendo que una operación se aplique dos veces.
        if (p.SqlState == "23505" &&
            p.ConstraintName == "ux_tbl_movimientos_inventario__operacion")
        {
            return (409, "WM013", "Esta operación ya fue aplicada",
                "El motor impidió una segunda aplicación del mismo id_operacion. " +
                "Consulte /api/inventario/movimientos?idOperacion= para ver el movimiento original.");
        }

        return (def.Http, def.Codigo, def.Titulo, p.MessageText);
    }
}
