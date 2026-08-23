using Dapper;
using MediatR;
using Wms.Application.Abstracciones;
using Wms.Application.Comun;
using Wms.Domain.Errores;

namespace Wms.Application.Inventario.ConsultarMovimientos;

public sealed record ConsultaMovimientos(
    long? ProductoId, long? AlmacenId, long? UsuarioId, string? Sku, string? IdOperacion,
    DateTime? Desde, DateTime? Hasta, string? Tipo, int? Pagina, int? PorPagina)
    : IRequest<Pagina<FilaMovimiento>>
{
    /// <summary>
    /// Ventana por omisión de 30 días. Sin ella, entrar a Movimientos leería
    /// la bitácora completa, que solo crece.
    /// </summary>
    public const int DiasPorOmision = 30;
}

public sealed record FilaMovimiento(
    long Id, Guid UuidMovimiento, DateTime CreadoEn, string TipoMovimiento, string TipoOrigen,
    string ProductoSku, string ProductoNombre, string AlmacenCodigo,
    int DeltaFisica, int FisicaAntes, int FisicaDespues,
    int DeltaReservada, int ReservadaAntes, int ReservadaDespues,
    string Estado, string? OrdenFolio, string? ClienteNombre,
    string IdOperacion, string? Motivo,
    long UsuarioId, string UsuarioCodigo, string UsuarioNombre, bool UsuarioVigente,
    long ProductoId, long AlmacenId,
    bool EstaDesactivado, long? ReversaId, DateTime? DesactivadoEn,
    string? DesactivadoPorNombre, string? MotivoDesactivacion,
    long? MovimientoRevertidoId, bool EsReversa,
    long Total);

public sealed class ManejadorConsultaMovimientos(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaMovimientos, Pagina<FilaMovimiento>>
{
    // Filtros por IDENTIFICADOR real, no por la etiqueta que se muestra: el
    // usuario y el producto se resuelven contra su llave. El SKU se acepta
    // como texto solo porque es un identificador natural del producto, y se
    // traduce a producto_id en la propia consulta.
    //
    // La ventana de fechas es obligatoria en la práctica (el manejador pone
    // 30 días si no llega) y ordena por (creado_en desc, id desc), que es
    // exactamente el índice ix_tbl_movimientos_inventario__fecha.
    private const string Sql = """
        select id, uuid_movimiento, creado_en, tipo_movimiento, tipo_origen,
               producto_sku, producto_nombre, almacen_codigo,
               delta_fisica, fisica_antes, fisica_despues,
               delta_reservada, reservada_antes, reservada_despues,
               estado, orden_folio, cliente_nombre,
               id_operacion, motivo,
               usuario_id, usuario_codigo, usuario_nombre, usuario_vigente,
               producto_id, almacen_id,
               esta_desactivado, reversa_id, desactivado_en,
               desactivado_por_nombre, motivo_desactivacion,
               movimiento_revertido_id, es_reversa,
               count(*) over() as total
          from wms.vw_movimientos_detalle
         where (@ProductoId::bigint  is null or producto_id = @ProductoId::bigint)
           and (@AlmacenId::bigint   is null or almacen_id  = @AlmacenId::bigint)
           and (@UsuarioId::bigint   is null or usuario_id  = @UsuarioId::bigint)
           and (@Sku::text           is null or producto_sku ilike '%' || @Sku::text || '%')
           and (@IdOperacion::text   is null or id_operacion = @IdOperacion::text)
           and (@Desde::timestamptz  is null or creado_en >= @Desde::timestamptz)
           and (@Hasta::timestamptz  is null or creado_en <  @Hasta::timestamptz)
           and (@Tipo::text          is null or tipo_movimiento = @Tipo::text)
         order by creado_en desc, id desc
         limit @Limite::int offset @Salto::int
        """;

    public async Task<Pagina<FilaMovimiento>> Handle(ConsultaMovimientos q, CancellationToken ct)
    {
        var desde = q.Desde ?? DateTime.UtcNow.AddDays(-ConsultaMovimientos.DiasPorOmision).Date;

        // `hasta` es INCLUSIVO para el usuario: si pide hasta el 22, espera ver
        // lo del 22 completo. Se traduce a "< 23 a las 00:00", que además deja
        // el predicado utilizable por el índice.
        DateTime? hasta = q.Hasta?.Date.AddDays(1);

        if (hasta is not null && desde >= hasta)
            throw new ExcepcionWms("WM012", 400,
                "El rango de fechas es inválido.",
                "La fecha inicial debe ser anterior o igual a la final.");

        var (pagina, porPagina, salto) = Paginado.Normalizar(q.Pagina, q.PorPagina);

        await using var c = await fabrica.AbrirAsync(ct);
        var filas = (await c.QueryAsync<FilaMovimiento>(new CommandDefinition(Sql, new
        {
            q.ProductoId, q.AlmacenId, q.UsuarioId,
            Sku = string.IsNullOrWhiteSpace(q.Sku) ? null : q.Sku.Trim(),
            IdOperacion = string.IsNullOrWhiteSpace(q.IdOperacion) ? null : q.IdOperacion.Trim(),
            Desde = desde, Hasta = hasta, q.Tipo,
            Limite = porPagina, Salto = salto
        }, cancellationToken: ct))).ToList();

        return new Pagina<FilaMovimiento>(filas, filas.Count > 0 ? filas[0].Total : 0, pagina, porPagina);
    }
}
