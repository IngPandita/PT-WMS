using Dapper;
using MediatR;
using Wms.Application.Comun.Operaciones;

namespace Wms.Application.Inventario.AjustarExistencia;

/// <summary>
/// La garantia de no duplicar NO vive aqui: vive en pk_tbl_operaciones y en
/// ux_tbl_movimientos_inventario__operacion. Este manejador solo declara cual
/// es la intencion y cual el trabajo; el EjecutorIdempotente pone las fases.
/// </summary>
public sealed class ManejadorAjustarExistencia(EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<ComandoAjustarExistencia, RespuestaAjuste>
{
    public async Task<RespuestaAjuste> Handle(ComandoAjustarExistencia cmd, CancellationToken ct)
    {
        var intencion = new Dictionary<string, object?>
        {
            ["producto_id"]     = cmd.ProductoId,
            ["almacen_id"]      = cmd.AlmacenId,
            ["delta"]           = cmd.Delta,
            ["tipo_movimiento"] = cmd.TipoMovimiento,
            ["usuario_id"]      = contexto.UsuarioId,
            // Motivo y VersionEsperada quedan FUERA a proposito: ver HuellaPeticion.
        };

        var r = await ejecutor.EjecutarAsync(contexto, HuellaPeticion.RutaAjuste, intencion,
            async (conexion, tx, token) =>
            {
                var fila = await conexion.QuerySingleAsync<FilaInventario>(new CommandDefinition(
                    "select producto_id, almacen_id, cantidad_fisica, cantidad_reservada, " +
                    "       cantidad_disponible, version_concurrencia " +
                    "  from wms.fn_ajustar_existencia(" +
                    "       @ProductoId, @AlmacenId, @Delta, @TipoMovimiento, @UsuarioId, " +
                    "       @IdOperacion, 'AJUSTE_RAPIDO', null, null, @Motivo, @VersionEsperada)",
                    new
                    {
                        cmd.ProductoId, cmd.AlmacenId, cmd.Delta, cmd.TipoMovimiento,
                        UsuarioId = contexto.UsuarioId,
                        IdOperacion = contexto.IdOperacionCompleto,
                        cmd.Motivo, cmd.VersionEsperada
                    },
                    transaction: tx, cancellationToken: token));

                return new RespuestaAjuste(
                    fila.producto_id, fila.almacen_id, fila.cantidad_fisica, fila.cantidad_reservada,
                    fila.cantidad_disponible, fila.version_concurrencia,
                    contexto.IdOperacionCompleto, FueReenvio: false);
            }, ct);

        return r.Valor with { FueReenvio = r.FueReenvio };
    }

    private sealed record FilaInventario(
        long producto_id, long almacen_id, int cantidad_fisica, int cantidad_reservada,
        int cantidad_disponible, long version_concurrencia);
}
