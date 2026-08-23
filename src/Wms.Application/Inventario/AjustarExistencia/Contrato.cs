using MediatR;

namespace Wms.Application.Inventario.AjustarExistencia;

public sealed record ComandoAjustarExistencia(
    long ProductoId,
    long AlmacenId,
    int Delta,
    string TipoMovimiento,
    string? Motivo,
    long? VersionEsperada) : IRequest<RespuestaAjuste>;

public sealed record RespuestaAjuste(
    long ProductoId,
    long AlmacenId,
    int CantidadFisica,
    int CantidadReservada,
    int CantidadDisponible,
    long VersionConcurrencia,
    string IdOperacion,
    bool FueReenvio);
