using Dapper;
using MediatR;
using Wms.Application.Abstracciones;
using Wms.Application.Comun;

namespace Wms.Application.Consultas;

/// <summary>
/// Fila generica de catalogo o indicador. C# no admite 'dynamic' como
/// argumento de tipo de una interfaz implementada, y un diccionario serializa
/// a un objeto JSON exactamente igual.
/// </summary>
public sealed class Fila : Dictionary<string, object?>
{
    public static Fila Desde(IDictionary<string, object> origen)
    {
        var destino = new Fila();
        foreach (var par in origen) destino[par.Key] = par.Value;
        return destino;
    }
}

// =====================================================================
//  Todas las lecturas se apoyan en las vistas del esquema. La API no
//  reconstruye reglas que la base ya expresa: el localizador
//  SKU@CODIGO_ALMACEN, el estado derivado de un movimiento y los
//  indicadores viven en una sola definicion, no en dos.
// =====================================================================

public sealed record ConsultaOrdenes(string? Estatus, long? ClienteId, long? AlmacenId,
    int? Pagina, int? PorPagina) : IRequest<Pagina<FilaOrdenDetalle>>;

public sealed record FilaOrdenDetalle(
    long Id, string Folio, string Estatus, decimal MontoTotal,
    string ClienteCodigo, string ClienteNombre, bool ClienteVigente,
    string AlmacenCodigo, string AlmacenNombre,
    long Partidas, long Unidades,
    DateTime? ConfirmadoEn, DateTime? EnviadoEn, DateTime? CanceladoEn, string? MotivoCancelacion,
    string? Notas, string CreadoPorCodigo, string CreadoPorNombre,
    long VersionConcurrencia, DateTime CreadoEn, long Total);

public sealed class ManejadorConsultaOrdenes(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaOrdenes, Pagina<FilaOrdenDetalle>>
{
    private const string Sql = """
        select id, folio, estatus, monto_total,
               cliente_codigo, cliente_nombre, cliente_vigente,
               almacen_codigo, almacen_nombre, partidas, unidades,
               confirmado_en, enviado_en, cancelado_en, motivo_cancelacion,
               notas, creado_por_codigo, creado_por_nombre,
               version_concurrencia, creado_en,
               count(*) over() as total
          from wms.vw_ordenes_detalle
         where (@Estatus::text     is null or estatus = @Estatus::text)
           and (@ClienteId::bigint is null or cliente_codigo =
                    (select codigo from wms.cat_clientes where id = @ClienteId::bigint))
           and (@AlmacenId::bigint is null or almacen_codigo =
                    (select codigo from wms.cat_almacenes where id = @AlmacenId::bigint))
         order by creado_en desc, id desc
         limit @Limite::int offset @Salto::int
        """;

    public async Task<Pagina<FilaOrdenDetalle>> Handle(ConsultaOrdenes q, CancellationToken ct)
    {
        var (pagina, porPagina, salto) = Paginado.Normalizar(q.Pagina, q.PorPagina);
        await using var c = await fabrica.AbrirAsync(ct);
        var filas = (await c.QueryAsync<FilaOrdenDetalle>(new CommandDefinition(Sql,
            new { q.Estatus, q.ClienteId, q.AlmacenId, Limite = porPagina, Salto = salto },
            cancellationToken: ct))).ToList();
        return new Pagina<FilaOrdenDetalle>(filas, filas.Count > 0 ? filas[0].Total : 0, pagina, porPagina);
    }
}

public sealed record ConsultaPartidas(long OrdenId) : IRequest<IReadOnlyList<FilaPartida>>;

public sealed record FilaPartida(
    long Id, long OrdenId, long ProductoId, string ProductoSku, string ProductoNombre,
    int Cantidad, decimal PrecioUnitarioHistorico, decimal ImporteLinea,
    decimal ProductoPrecioVigente, string Localizador);

public sealed class ManejadorConsultaPartidas(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaPartidas, IReadOnlyList<FilaPartida>>
{
    public async Task<IReadOnlyList<FilaPartida>> Handle(ConsultaPartidas q, CancellationToken ct)
    {
        await using var c = await fabrica.AbrirAsync(ct);
        return (await c.QueryAsync<FilaPartida>(new CommandDefinition(
            "select id, orden_id, producto_id, producto_sku, producto_nombre, cantidad, " +
            "       precio_unitario_historico, importe_linea, producto_precio_vigente, localizador " +
            "  from wms.vw_orden_partidas where orden_id = @OrdenId order by producto_sku",
            new { q.OrdenId }, cancellationToken: ct))).ToList();
    }
}

// ---------------------------------------------------------------------
//  Catalogos
// ---------------------------------------------------------------------

public sealed record ConsultaCatalogo(string Recurso, bool SoloVigentes,
    int? Pagina = null, int? PorPagina = null) : IRequest<Pagina<Fila>>;

public sealed class ManejadorConsultaCatalogo(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaCatalogo, Pagina<Fila>>
{
    // Lista blanca: el nombre del recurso NUNCA se concatena crudo al SQL.
    private static readonly Dictionary<string, (string Tabla, string Vigencia, string Orden)> Permitidos = new()
    {
        ["categorias"] = ("wms.cat_categorias", "es_activo", "codigo"),
        ["almacenes"]  = ("wms.cat_almacenes",  "es_activo", "codigo"),
        ["clientes"]   = ("wms.cat_clientes",   "es_activo", "codigo"),
        ["usuarios"]   = ("wms.cat_usuarios",   "es_activo", "codigo"),
        ["productos"]  = ("wms.cat_productos",  "estatus = 'ACTIVO'", "sku"),
    };

    public async Task<Pagina<Fila>> Handle(ConsultaCatalogo q, CancellationToken ct)
    {
        if (!Permitidos.TryGetValue(q.Recurso, out var def))
            throw new KeyNotFoundException($"Catalogo desconocido: '{q.Recurso}'.");

        // Sin paginación explícita se sirve el catálogo hasta el techo de la
        // API. Es lo que necesitan los combos de la interfaz, que quieren el
        // catálogo entero y no una página.
        //
        // El techo es REAL: un catálogo con más de MaximoPorPagina registros
        // llega recortado a los combos. Con los volúmenes de este sistema
        // (categorías, almacenes, operadores, clientes) no se alcanza, y la
        // pantalla de Catálogos —que sí puede crecer— pide sus 25 explícitos.
        // Se deja escrito porque un tope silencioso se lee como «vinieron
        // todos» justo cuando no vinieron.
        var (pagina, porPagina, salto) =
            Paginado.Normalizar(q.Pagina, q.PorPagina ?? Paginado.MaximoPorPagina);
        var filtro = q.SoloVigentes ? $"where {def.Vigencia}" : string.Empty;

        await using var c = await fabrica.AbrirAsync(ct);
        var filas = (await c.QueryAsync(new CommandDefinition(
            $"select *, count(*) over() as total from {def.Tabla} {filtro} " +
            $"order by {def.Orden} limit @Limite offset @Salto",
            new { Limite = porPagina, Salto = salto }, cancellationToken: ct)))
            .Cast<IDictionary<string, object>>().ToList();

        var total = filas.Count > 0 ? Convert.ToInt64(filas[0]["total"]) : 0;
        var elementos = filas.Select(f => { f.Remove("total"); return Fila.Desde(f); }).ToList();
        return new Pagina<Fila>(elementos, total, pagina, porPagina);
    }
}

// ---------------------------------------------------------------------
//  Indicadores del dashboard
// ---------------------------------------------------------------------

public sealed record ConsultaIndicadores(int DiasDemanda = 30, int TopN = 10) : IRequest<Indicadores>;

public sealed record Indicadores(
    Fila Operacion,
    IReadOnlyList<Fila> PorAlmacen,
    IReadOnlyList<Fila> SerieDiaria,
    IReadOnlyList<Fila> AportacionPorUsuario,
    IReadOnlyList<Fila> MayorDemanda,
    IReadOnlyList<Fila> ExistenciaInsuficiente,
    int DiasDemanda);

public sealed class ManejadorConsultaIndicadores(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaIndicadores, Indicadores>
{
    public async Task<Indicadores> Handle(ConsultaIndicadores q, CancellationToken ct)
    {
        await using var c = await fabrica.AbrirAsync(ct);

        // Una sola ida y vuelta para las cuatro fuentes del dashboard.
        await using var multi = await c.QueryMultipleAsync(new CommandDefinition(
            """
            select * from wms.vw_indicadores_operacion;
            select * from wms.vw_indicadores_almacen order by almacen_codigo;
            select * from wms.vw_serie_movimientos_diaria order by dia;
            select * from wms.vw_aportacion_por_usuario order by delta_fisico_total desc limit 20;
            select * from wms.fn_productos_mayor_demanda(@Dias, @TopN);
            select * from wms.vw_existencia_insuficiente
             order by faltante desc, producto_sku limit @TopN;
            """, new { Dias = Math.Clamp(q.DiasDemanda, 1, 365), TopN = Math.Clamp(q.TopN, 1, 50) },
            cancellationToken: ct));

        var operacion = Fila.Desde((IDictionary<string, object>)await multi.ReadSingleAsync());
        var porAlmacen = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().Select(Fila.Desde).ToList();
        var serie = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().Select(Fila.Desde).ToList();
        var aportacion = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().Select(Fila.Desde).ToList();

        var demanda = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().Select(Fila.Desde).ToList();
        var faltantes = (await multi.ReadAsync()).Cast<IDictionary<string, object>>().Select(Fila.Desde).ToList();

        return new Indicadores(operacion, porAlmacen, serie, aportacion,
            demanda, faltantes, Math.Clamp(q.DiasDemanda, 1, 365));
    }
}
