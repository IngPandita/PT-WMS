using Dapper;
using MediatR;
using Wms.Application.Abstracciones;
using Wms.Application.Comun;
using Wms.Application.Consultas;

namespace Wms.Application.Importacion;

public sealed record ConsultaResultadoImportacion(long LoteId, int? Pagina = null, int? PorPagina = null)
    : IRequest<Fila?>;

/// <summary>
/// El enunciado exige que el usuario reciba informacion suficiente para
/// conocer el resultado, y que siga siendo consultable despues. El lote lleva
/// sus contadores; el resumen agrega por estatus, accion y codigo de error,
/// para que el frontend pueda agrupar sin parsear mensajes en espanol.
///
/// Los renglones van PAGINADOS, igual que el resto de los listados. Antes se
/// recortaban con un `limit 1000` mudo: un lote de 3 000 renglones se veia
/// completo y no lo estaba. Los contadores del lote y el resumen siguen
/// describiendo el lote ENTERO, no la pagina.
/// </summary>
public sealed class ManejadorConsultaResultadoImportacion(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaResultadoImportacion, Fila?>
{
    public async Task<Fila?> Handle(ConsultaResultadoImportacion q, CancellationToken ct)
    {
        await using var c = await fabrica.AbrirAsync(ct);

        var lote = await c.QuerySingleOrDefaultAsync(new CommandDefinition(
            "select * from wms.tbl_lotes_importacion where id = @Id",
            new { Id = q.LoteId }, cancellationToken: ct));
        if (lote is null) return null;

        var resumen = await c.QueryAsync(new CommandDefinition(
            "select estatus, accion, codigo_error, renglones, unidades " +
            "  from wms.vw_importacion_resultado where lote_id = @Id " +
            " order by estatus, accion nulls first",
            new { Id = q.LoteId }, cancellationToken: ct));

        var (pagina, porPagina, salto) = Paginado.Normalizar(q.Pagina, q.PorPagina);

        var filas = (await c.QueryAsync(new CommandDefinition(
            "select numero_renglon, estatus, accion, codigo_error, mensaje_error, " +
            "       producto_id, almacen_id, cantidad_aplicada, movimiento_id, carga_original, " +
            "       count(*) over() as total " +
            "  from wms.tbl_renglones_importacion where lote_id = @Id " +
            " order by numero_renglon limit @Limite offset @Salto",
            new { Id = q.LoteId, Limite = porPagina, Salto = salto }, cancellationToken: ct)))
            .Cast<IDictionary<string, object>>().ToList();

        var total = filas.Count > 0 ? Convert.ToInt64(filas[0]["total"]) : 0;
        var renglones = filas.Select(f => { f.Remove("total"); return Fila.Desde(f); }).ToList();

        var salida = Fila.Desde((IDictionary<string, object>)lote);
        salida["resumen"] = resumen.Cast<IDictionary<string, object>>().Select(Fila.Desde).ToList();
        salida["renglones"] = new Pagina<Fila>(renglones, total, pagina, porPagina);
        return salida;
    }
}
