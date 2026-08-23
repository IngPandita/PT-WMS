using Dapper;
using FluentValidation;
using MediatR;
using Wms.Application.Comun.Operaciones;

namespace Wms.Application.Inventario.EstablecerExistencia;

public sealed record ComandoEstablecerExistencia(
    long ProductoId, long AlmacenId, int CantidadObjetivo,
    string? Motivo, long? VersionEsperada) : IRequest<RespuestaEstablecer>;

public sealed record RespuestaEstablecer(
    long ProductoId, long AlmacenId,
    int CantidadFisica, int CantidadReservada, int CantidadDisponible,
    long VersionConcurrencia, string IdOperacion, bool FueReenvio);

public sealed class ValidadorEstablecerExistencia : AbstractValidator<ComandoEstablecerExistencia>
{
    public ValidadorEstablecerExistencia()
    {
        RuleFor(c => c.ProductoId).GreaterThan(0);
        RuleFor(c => c.AlmacenId).GreaterThan(0);
        // Entero y no negativo. El tipo int ya excluye decimales en el
        // contrato; el frontend además impide teclearlos.
        RuleFor(c => c.CantidadObjetivo)
            .GreaterThanOrEqualTo(0).WithMessage("La existencia objetivo no puede ser negativa.")
            .LessThanOrEqualTo(100_000_000).WithMessage("La existencia objetivo excede el máximo razonable.");
        RuleFor(c => c.Motivo).MaximumLength(500);
    }
}

/// <summary>
/// Ajuste manual a cantidad OBJETIVO.
///
/// Se eligió el objetivo absoluto y no el delta porque es lo que hace un
/// conteo físico: el operador ve 15 en el anaquel y captura 15. Pero la
/// conversión a delta NO ocurre aquí: viaja el objetivo y la base lo convierte
/// bajo el row lock. Calcularlo en el cliente sería una condición de carrera
/// —si otro operador mueve el producto entre la lectura y el envío, el delta
/// saldría de un valor ya obsoleto—.
///
/// El resultado es un movimiento AJUSTE auditable con el delta real, no una
/// escritura silenciosa sobre la existencia.
/// </summary>
public sealed class ManejadorEstablecerExistencia(EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<ComandoEstablecerExistencia, RespuestaEstablecer>
{
    public async Task<RespuestaEstablecer> Handle(ComandoEstablecerExistencia cmd, CancellationToken ct)
    {
        var intencion = new Dictionary<string, object?>
        {
            ["producto_id"]     = cmd.ProductoId,
            ["almacen_id"]      = cmd.AlmacenId,
            ["objetivo"]        = cmd.CantidadObjetivo,
            ["usuario_id"]      = contexto.UsuarioId,
            // El motivo queda fuera de la huella, igual que en el ajuste por
            // delta: corregir su texto entre reenvíos no es otra intención.
        };

        var r = await ejecutor.EjecutarAsync(contexto, HuellaPeticion.RutaEstablecer, intencion,
            async (conexion, tx, token) =>
            {
                var fila = await conexion.QuerySingleAsync<FilaInventario>(new CommandDefinition(
                    "select producto_id, almacen_id, cantidad_fisica, cantidad_reservada, " +
                    "       cantidad_disponible, version_concurrencia " +
                    "  from wms.fn_establecer_existencia(" +
                    "       @ProductoId, @AlmacenId, @Objetivo, @UsuarioId, @IdOperacion, " +
                    "       @Motivo, @VersionEsperada)",
                    new
                    {
                        cmd.ProductoId, cmd.AlmacenId,
                        Objetivo = cmd.CantidadObjetivo,
                        UsuarioId = contexto.UsuarioId,
                        IdOperacion = contexto.IdOperacionCompleto,
                        cmd.Motivo, cmd.VersionEsperada
                    }, transaction: tx, cancellationToken: token));

                return new RespuestaEstablecer(
                    fila.producto_id, fila.almacen_id, fila.cantidad_fisica, fila.cantidad_reservada,
                    fila.cantidad_disponible, fila.version_concurrencia,
                    contexto.IdOperacionCompleto, false);
            }, ct);

        return r.Valor with { FueReenvio = r.FueReenvio };
    }

    private sealed record FilaInventario(
        long producto_id, long almacen_id, int cantidad_fisica, int cantidad_reservada,
        int cantidad_disponible, long version_concurrencia);
}
