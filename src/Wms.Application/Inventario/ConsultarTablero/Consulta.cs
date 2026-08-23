using Dapper;
using MediatR;
using Wms.Application.Abstracciones;
using Wms.Application.Comun;

namespace Wms.Application.Inventario.ConsultarTablero;

public sealed record ConsultaTablero(
    long? AlmacenId, string? Texto, bool SoloExistenciaBaja, int? Pagina, int? PorPagina)
    : IRequest<Pagina<FilaTablero>>;

/// <summary>
/// Los nombres corresponden a las columnas snake_case de la vista; Dapper las
/// empareja con MatchNamesWithUnderscores. No se usan alias en el SQL porque
/// Postgres los devuelve en minusculas y romperia el emparejamiento posicional
/// del record.
/// </summary>
public sealed record FilaTablero(
    long ProductoId, long AlmacenId, string ProductoSku, string ProductoNombre,
    decimal ProductoPrecio, string ProductoEstatus, string CategoriaCodigo, string CategoriaNombre,
    string AlmacenCodigo, string AlmacenNombre, string Localizador,
    int CantidadFisica, int CantidadReservada, int CantidadDisponible, int CantidadMinima,
    bool EsExistenciaBaja, long VersionConcurrencia, DateTime ActualizadoEn,
    long Total);

public sealed class ManejadorConsultaTablero(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaTablero, Pagina<FilaTablero>>
{
    // LIMIT/OFFSET con count(*) over() en la MISMA consulta: la interfaz
    // muestra "pagina X de N" y el total debe corresponder exactamente a las
    // filas devueltas, cosa que dos consultas separadas no garantizan.
    // Los casts explicitos evitan que Postgres no pueda inferir el tipo de un
    // parametro nulo dentro de una concatenacion.
    private const string Sql = """
        select producto_id, almacen_id, producto_sku, producto_nombre,
               producto_precio, producto_estatus, categoria_codigo, categoria_nombre,
               almacen_codigo, almacen_nombre, localizador,
               cantidad_fisica, cantidad_reservada, cantidad_disponible, cantidad_minima,
               es_existencia_baja, version_concurrencia, actualizado_en,
               count(*) over() as total
          from wms.vw_tablero_inventario
         where (@AlmacenId::bigint is null or almacen_id = @AlmacenId::bigint)
           and (@Texto::text is null
                or producto_sku    ilike '%' || @Texto::text || '%'
                or producto_nombre ilike '%' || @Texto::text || '%')
           and (@SoloExistenciaBaja::boolean = false or es_existencia_baja)
         order by producto_sku, almacen_codigo
         limit @Limite::int offset @Salto::int
        """;

    public async Task<Pagina<FilaTablero>> Handle(ConsultaTablero q, CancellationToken ct)
    {
        var (pagina, porPagina, salto) = Paginado.Normalizar(q.Pagina, q.PorPagina);

        await using var conexion = await fabrica.AbrirAsync(ct);
        var filas = (await conexion.QueryAsync<FilaTablero>(new CommandDefinition(Sql, new
        {
            q.AlmacenId, q.Texto, q.SoloExistenciaBaja,
            Limite = porPagina, Salto = salto
        }, cancellationToken: ct))).ToList();

        // El total viaja repetido en cada fila (count(*) over()); si la pagina
        // esta vacia, el conjunto filtrado tambien lo esta.
        return new Pagina<FilaTablero>(filas, filas.Count > 0 ? filas[0].Total : 0, pagina, porPagina);
    }
}
