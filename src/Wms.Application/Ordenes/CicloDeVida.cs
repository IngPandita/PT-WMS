using Dapper;
using FluentValidation;
using MediatR;
using Wms.Application.Comun.Operaciones;

namespace Wms.Application.Ordenes;

// =====================================================================
//  Contratos
// =====================================================================

public sealed record PartidaEntrada(long ProductoId, int Cantidad);

public sealed record ComandoCrearOrden(
    long ClienteId, long AlmacenId, string? Notas, IReadOnlyList<PartidaEntrada> Partidas)
    : IRequest<RespuestaOrden>;

public sealed record ComandoConfirmarOrden(long OrdenId) : IRequest<RespuestaOrden>;
public sealed record ComandoEnviarOrden(long OrdenId)    : IRequest<RespuestaOrden>;
public sealed record ComandoCancelarOrden(long OrdenId, string Motivo) : IRequest<RespuestaOrden>;

public sealed record RespuestaOrden(
    long Id, string Folio, string Estatus, decimal MontoTotal,
    long VersionConcurrencia, string IdOperacion, bool FueReenvio);

// =====================================================================
//  Validadores
// =====================================================================

public sealed class ValidadorCrearOrden : AbstractValidator<ComandoCrearOrden>
{
    public ValidadorCrearOrden()
    {
        RuleFor(c => c.ClienteId).GreaterThan(0);
        RuleFor(c => c.AlmacenId).GreaterThan(0);
        RuleFor(c => c.Notas).MaximumLength(1000);
        RuleFor(c => c.Partidas).NotEmpty()
            .WithMessage("Una orden debe llevar al menos una partida.");
        RuleForEach(c => c.Partidas).ChildRules(p =>
        {
            p.RuleFor(x => x.ProductoId).GreaterThan(0);
            p.RuleFor(x => x.Cantidad).GreaterThan(0)
                .WithMessage("La cantidad de una partida debe ser positiva.");
        });
        RuleFor(c => c.Partidas)
            .Must(ps => ps.Select(p => p.ProductoId).Distinct().Count() == ps.Count)
            .WithMessage("Un producto no puede aparecer dos veces en la misma orden; sume las cantidades.");
    }
}

public sealed class ValidadorCancelarOrden : AbstractValidator<ComandoCancelarOrden>
{
    public ValidadorCancelarOrden()
    {
        RuleFor(c => c.OrdenId).GreaterThan(0);
        RuleFor(c => c.Motivo).NotEmpty().MaximumLength(500)
            .WithMessage("Cancelar exige un motivo: queda en el historial de la orden.");
    }
}

// =====================================================================
//  Manejadores
// =====================================================================

internal sealed record FilaOrden(
    long id, string folio, string estatus, decimal monto_total, long version_concurrencia);

public sealed class ManejadorCrearOrden(EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<ComandoCrearOrden, RespuestaOrden>
{
    public async Task<RespuestaOrden> Handle(ComandoCrearOrden cmd, CancellationToken ct)
    {
        var intencion = new Dictionary<string, object?>
        {
            ["cliente_id"] = cmd.ClienteId,
            ["almacen_id"] = cmd.AlmacenId,
            ["usuario_id"] = contexto.UsuarioId,
            ["partidas"]   = HuellaPeticion.HuellaPartidas(
                                 cmd.Partidas.Select(p => (p.ProductoId, p.Cantidad))),
            // Las notas quedan fuera: son editables y no definen la intencion.
        };

        var r = await ejecutor.EjecutarAsync(contexto, HuellaPeticion.RutaCrearOrden, intencion,
            async (conexion, tx, token) =>
            {
                // tbl_ordenes.id_operacion es UNICO: el alta tambien tiene
                // barrera de motor, no solo el sobre de idempotencia.
                var orden = await conexion.QuerySingleAsync<FilaOrden>(new CommandDefinition(
                    "insert into wms.tbl_ordenes " +
                    "  (cliente_id, almacen_id, id_operacion, creado_por_usuario_id, notas) " +
                    "values (@ClienteId, @AlmacenId, @IdOperacion, @UsuarioId, @Notas) " +
                    "returning id, folio, estatus, monto_total, version_concurrencia",
                    new
                    {
                        cmd.ClienteId, cmd.AlmacenId, cmd.Notas,
                        IdOperacion = contexto.IdOperacionCompleto,
                        UsuarioId = contexto.UsuarioId
                    }, transaction: tx, cancellationToken: token));

                foreach (var p in cmd.Partidas)
                {
                    // nombre_historico y precio_unitario_historico los sella el
                    // trigger desde el catalogo: el cliente no los envia.
                    await conexion.ExecuteAsync(new CommandDefinition(
                        "insert into wms.rel_orden_producto " +
                        "  (orden_id, producto_id, cantidad, nombre_historico, precio_unitario_historico) " +
                        "values (@OrdenId, @ProductoId, @Cantidad, '', null)",
                        new { OrdenId = orden.id, p.ProductoId, p.Cantidad },
                        transaction: tx, cancellationToken: token));
                }

                // El total lo recalcula un trigger; se relee para devolverlo.
                var final = await conexion.QuerySingleAsync<FilaOrden>(new CommandDefinition(
                    "select id, folio, estatus, monto_total, version_concurrencia " +
                    "  from wms.tbl_ordenes where id = @Id",
                    new { Id = orden.id }, transaction: tx, cancellationToken: token));

                return new RespuestaOrden(final.id, final.folio, final.estatus, final.monto_total,
                    final.version_concurrencia, contexto.IdOperacionCompleto, false);
            }, ct);

        return r.Valor with { FueReenvio = r.FueReenvio };
    }
}

/// <summary>
/// Confirmar, enviar y cancelar comparten forma: una sola llamada a la
/// primitiva atomica correspondiente, que ya resuelve reservas, liberaciones
/// y orden determinista de locks.
/// </summary>
public abstract class ManejadorTransicionOrden<TComando>(
    EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<TComando, RespuestaOrden> where TComando : IRequest<RespuestaOrden>
{
    protected abstract string Accion { get; }
    protected abstract string ClaveRuta { get; }
    protected abstract long OrdenId(TComando cmd);
    protected abstract string Sql { get; }
    protected virtual object Parametros(TComando cmd) => new
    {
        OrdenId = OrdenId(cmd),
        UsuarioId = contexto.UsuarioId,
        IdOperacion = contexto.IdOperacionCompleto
    };

    public async Task<RespuestaOrden> Handle(TComando cmd, CancellationToken ct)
    {
        var intencion = new Dictionary<string, object?>
        {
            ["accion"]     = Accion,
            ["orden_id"]   = OrdenId(cmd),
            ["usuario_id"] = contexto.UsuarioId,
        };

        var r = await ejecutor.EjecutarAsync(contexto, ClaveRuta, intencion,
            async (conexion, tx, token) =>
            {
                var fila = await conexion.QuerySingleAsync<FilaOrden>(new CommandDefinition(
                    Sql, Parametros(cmd), transaction: tx, cancellationToken: token));

                return new RespuestaOrden(fila.id, fila.folio, fila.estatus, fila.monto_total,
                    fila.version_concurrencia, contexto.IdOperacionCompleto, false);
            }, ct);

        return r.Valor with { FueReenvio = r.FueReenvio };
    }
}

public sealed class ManejadorConfirmarOrden(EjecutorIdempotente e, ContextoOperacion c)
    : ManejadorTransicionOrden<ComandoConfirmarOrden>(e, c)
{
    protected override string Accion => "CONFIRMAR";
    protected override string ClaveRuta => HuellaPeticion.RutaConfirmarOrden;
    protected override long OrdenId(ComandoConfirmarOrden cmd) => cmd.OrdenId;
    protected override string Sql =>
        "select id, folio, estatus, monto_total, version_concurrencia " +
        "  from wms.fn_confirmar_orden(@OrdenId, @UsuarioId, @IdOperacion)";
}

public sealed class ManejadorEnviarOrden(EjecutorIdempotente e, ContextoOperacion c)
    : ManejadorTransicionOrden<ComandoEnviarOrden>(e, c)
{
    protected override string Accion => "ENVIAR";
    protected override string ClaveRuta => HuellaPeticion.RutaEnviarOrden;
    protected override long OrdenId(ComandoEnviarOrden cmd) => cmd.OrdenId;
    protected override string Sql =>
        "select id, folio, estatus, monto_total, version_concurrencia " +
        "  from wms.fn_enviar_orden(@OrdenId, @UsuarioId, @IdOperacion)";
}

public sealed class ManejadorCancelarOrden(EjecutorIdempotente e, ContextoOperacion c)
    : ManejadorTransicionOrden<ComandoCancelarOrden>(e, c)
{
    private readonly ContextoOperacion _contexto = c;

    protected override string Accion => "CANCELAR";
    protected override string ClaveRuta => HuellaPeticion.RutaCancelarOrden;
    protected override long OrdenId(ComandoCancelarOrden cmd) => cmd.OrdenId;
    protected override string Sql =>
        "select id, folio, estatus, monto_total, version_concurrencia " +
        "  from wms.fn_cancelar_orden(@OrdenId, @Motivo, @UsuarioId, @IdOperacion)";

    // El motivo viaja como parametro pero NO entra en la huella: corregir su
    // texto entre reenvios no debe convertir la operacion en otra distinta.
    protected override object Parametros(ComandoCancelarOrden cmd) => new
    {
        cmd.OrdenId,
        cmd.Motivo,
        UsuarioId = _contexto.UsuarioId,
        IdOperacion = _contexto.IdOperacionCompleto
    };
}
