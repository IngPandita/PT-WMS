using Dapper;
using FluentValidation;
using MediatR;
using Wms.Application.Abstracciones;
using Wms.Application.Comun.Operaciones;
using Wms.Application.Consultas;

namespace Wms.Application.Movimientos;

// =====================================================================
//  Detalle de un movimiento
// =====================================================================

public sealed record ConsultaDetalleMovimiento(long Id) : IRequest<Fila?>;

public sealed class ManejadorDetalleMovimiento(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaDetalleMovimiento, Fila?>
{
    public async Task<Fila?> Handle(ConsultaDetalleMovimiento q, CancellationToken ct)
    {
        await using var c = await fabrica.AbrirAsync(ct);
        var fila = await c.QuerySingleOrDefaultAsync(new CommandDefinition(
            "select * from wms.vw_movimientos_detalle where id = @Id",
            new { q.Id }, cancellationToken: ct));
        return fila is null ? null : Fila.Desde((IDictionary<string, object>)fila);
    }
}

// =====================================================================
//  Desactivación (reversa)
// =====================================================================

public sealed record ComandoRevertirMovimiento(long MovimientoId, string Motivo)
    : IRequest<RespuestaReversa>;

public sealed record RespuestaReversa(
    long ReversaId, long MovimientoRevertidoId, string TipoMovimiento,
    int DeltaFisica, int FisicaAntes, int FisicaDespues,
    string IdOperacion, bool FueReenvio);

public sealed class ValidadorRevertirMovimiento : AbstractValidator<ComandoRevertirMovimiento>
{
    public ValidadorRevertirMovimiento()
    {
        RuleFor(c => c.MovimientoId).GreaterThan(0);
        RuleFor(c => c.Motivo).NotEmpty().MaximumLength(500)
            .WithMessage("Desactivar un movimiento exige un motivo: queda en el historial.");
    }
}

/// <summary>
/// Desactivar un movimiento NO edita ni borra su renglón.
///
/// La bitácora es de solo inserción y esa garantía no se negocia: lo que se
/// hace es registrar el asiento contrario, exactamente como una póliza de
/// reversa en contabilidad. Con eso la existencia se recalcula sola —la
/// reversa pasa por el mismo trigger que cualquier movimiento— y
/// sum(delta_fisica) sigue reconstruyendo cantidad_fisica.
///
/// La restricción a usuario 1 (SISTEMA) se valida en la función de base de
/// datos, no aquí: ocultar un botón no es una autorización, y esta capa
/// podría saltarse llamando directo a la API.
/// </summary>
public sealed class ManejadorRevertirMovimiento(EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<ComandoRevertirMovimiento, RespuestaReversa>
{
    public async Task<RespuestaReversa> Handle(ComandoRevertirMovimiento cmd, CancellationToken ct)
    {
        var intencion = new Dictionary<string, object?>
        {
            ["accion"]        = "REVERTIR",
            ["movimiento_id"] = cmd.MovimientoId,
            ["usuario_id"]    = contexto.UsuarioId,
        };

        var r = await ejecutor.EjecutarAsync(contexto, HuellaPeticion.RutaRevertirMovimiento, intencion,
            async (conexion, tx, token) =>
            {
                var fila = await conexion.QuerySingleAsync<FilaReversa>(new CommandDefinition(
                    "select id, movimiento_revertido_id, tipo_movimiento, " +
                    "       delta_fisica, fisica_antes, fisica_despues " +
                    "  from wms.fn_revertir_movimiento(@MovimientoId, @UsuarioId, @IdOperacion, @Motivo)",
                    new
                    {
                        cmd.MovimientoId,
                        UsuarioId = contexto.UsuarioId,
                        IdOperacion = contexto.IdOperacionCompleto,
                        cmd.Motivo
                    }, transaction: tx, cancellationToken: token));

                return new RespuestaReversa(
                    fila.id, fila.movimiento_revertido_id, fila.tipo_movimiento,
                    fila.delta_fisica, fila.fisica_antes, fila.fisica_despues,
                    contexto.IdOperacionCompleto, false);
            }, ct);

        return r.Valor with { FueReenvio = r.FueReenvio };
    }

    private sealed record FilaReversa(
        long id, long movimiento_revertido_id, string tipo_movimiento,
        int delta_fisica, int fisica_antes, int fisica_despues);
}
