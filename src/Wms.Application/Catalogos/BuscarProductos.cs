using Dapper;
using MediatR;
using Wms.Application.Abstracciones;

namespace Wms.Application.Catalogos;

public sealed record ConsultaBuscarProductos(string Texto, long? AlmacenId, int Limite)
    : IRequest<IReadOnlyList<ProductoEncontrado>>;

public sealed record ProductoEncontrado(
    long Id, string Sku, string Nombre, string CategoriaNombre,
    decimal PrecioUnitario, string Estatus,
    int? CantidadDisponible);

/// <summary>
/// Búsqueda parcial para el autocompletado de la orden.
///
/// Solo se buscan SKU y nombre: son los dos campos por los que un operador
/// identifica un producto. Barrer todas las columnas encarecería la consulta
/// y devolvería coincidencias sin sentido —el texto de una descripción, por
/// ejemplo—.
///
/// El resultado incluye la disponibilidad EN EL ALMACÉN de la orden cuando se
/// conoce: elegir un producto sin existencia solo para que la confirmación
/// falle después es una mala experiencia evitable.
/// </summary>
public sealed class ManejadorBuscarProductos(IFabricaConexion fabrica)
    : IRequestHandler<ConsultaBuscarProductos, IReadOnlyList<ProductoEncontrado>>
{
    // Los índices trigram (sku y nombre) resuelven el '%texto%'. El orden
    // prioriza las coincidencias por prefijo de SKU, que es como la gente
    // teclea cuando ya sabe lo que busca.
    private const string Sql = """
        select p.id, p.sku, p.nombre, c.nombre as categoria_nombre,
               p.precio_unitario, p.estatus,
               i.cantidad_disponible
          from wms.cat_productos p
          join wms.cat_categorias c on c.id = p.categoria_id
          left join wms.tbl_inventario i
                 on i.producto_id = p.id and i.almacen_id = @AlmacenId::bigint
         where p.estatus = 'ACTIVO'
           and (p.sku ilike '%' || @Texto::text || '%'
                or p.nombre ilike '%' || @Texto::text || '%')
         order by case when p.sku ilike @Texto::text || '%' then 0 else 1 end,
                  p.sku
         limit @Limite::int
        """;

    public async Task<IReadOnlyList<ProductoEncontrado>> Handle(
        ConsultaBuscarProductos q, CancellationToken ct)
    {
        var texto = q.Texto.Trim();
        // Con menos de dos caracteres la consulta devolvería medio catálogo.
        if (texto.Length < 2) return [];

        await using var c = await fabrica.AbrirAsync(ct);
        return (await c.QueryAsync<ProductoEncontrado>(new CommandDefinition(Sql,
            new { Texto = texto, q.AlmacenId, Limite = Math.Clamp(q.Limite, 1, 50) },
            cancellationToken: ct))).ToList();
    }
}
