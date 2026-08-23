using System.Data.Common;
using System.Globalization;
using System.Text;
using Dapper;
using Wms.Application.Abstracciones;
using Wms.Domain.Errores;

namespace Wms.Application.Inventario.Exportar;

public sealed record FiltroExportacion(
    long? AlmacenId, string? Texto, bool SoloExistenciaBaja);

/// <summary>
/// Exportación del tablero de inventario a CSV.
///
/// No pasa por MediatR a propósito: el resultado es un flujo, no un valor. Se
/// escribe renglón por renglón conforme el motor los entrega, así que ni la
/// API ni el navegador materializan el catálogo completo en memoria. Con
/// 40 productos da igual; con 40 000 es la diferencia entre funcionar y no.
/// </summary>
public sealed class ExportadorInventario(IFabricaConexion fabrica)
{
    /// <summary>Encabezados en el mismo orden y con los mismos nombres que la pantalla.</summary>
    private static readonly (string Titulo, Func<FilaExportacion, string> Valor)[] Columnas =
    [
        ("SKU",                 f => f.producto_sku),
        ("Producto",            f => f.producto_nombre),
        ("Categoría",           f => f.categoria_nombre),
        ("Almacén",             f => f.almacen_codigo),
        ("Nombre del almacén",  f => f.almacen_nombre),
        ("Localizador",         f => f.localizador),
        ("Existencia",          f => f.cantidad_fisica.ToString(Cultura)),
        ("Reservado",           f => f.cantidad_reservada.ToString(Cultura)),
        ("Disponible",          f => f.cantidad_disponible.ToString(Cultura)),
        ("Existencia mínima",   f => f.cantidad_minima.ToString(Cultura)),
        ("Por reponer",         f => f.es_existencia_baja ? "Sí" : "No"),
        ("Precio unitario",     f => f.producto_precio.ToString("0.00", Cultura)),
        ("Valor",               f => (f.producto_precio * f.cantidad_fisica).ToString("0.00", Cultura)),
        ("Estatus del producto",f => f.producto_estatus),
        ("Actualizado",         f => f.actualizado_en.ToString("yyyy-MM-dd HH:mm:ss", Cultura)),
    ];

    private static readonly CultureInfo Cultura = CultureInfo.InvariantCulture;

    private const string Sql = """
        select producto_sku, producto_nombre, categoria_nombre,
               almacen_codigo, almacen_nombre, localizador,
               cantidad_fisica, cantidad_reservada, cantidad_disponible, cantidad_minima,
               es_existencia_baja, producto_precio, producto_estatus, actualizado_en
          from wms.vw_tablero_inventario
         where (@AlmacenId::bigint is null or almacen_id = @AlmacenId::bigint)
           and (@Texto::text is null
                or producto_sku    ilike '%' || @Texto::text || '%'
                or producto_nombre ilike '%' || @Texto::text || '%')
           and (@SoloExistenciaBaja::boolean = false or es_existencia_baja)
         order by producto_sku, almacen_codigo
        """;

    /// <summary>
    /// Escribe el CSV en el flujo destino. El BOM va delante para que Excel en
    /// es-MX no destroce los acentos al abrirlo con doble clic.
    /// </summary>
    public async Task EscribirCsvAsync(Stream destino, FiltroExportacion filtro, CancellationToken ct)
    {
        await using var escritor = new StreamWriter(destino, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        await escritor.WriteLineAsync(string.Join(',', Columnas.Select(c => Escapar(c.Titulo))));

        await using var conexion = await fabrica.AbrirAsync(ct);
        // QueryUnbufferedAsync no acepta CommandDefinition: recibe el SQL y los
        // parametros directo. La cancelacion se propaga con WithCancellation.
        var filas = conexion.QueryUnbufferedAsync<FilaExportacion>(
            Sql, new { filtro.AlmacenId, filtro.Texto, filtro.SoloExistenciaBaja });

        await foreach (var fila in filas.WithCancellation(ct))
        {
            await escritor.WriteLineAsync(string.Join(',', Columnas.Select(c => Escapar(c.Valor(fila)))));
        }
        await escritor.FlushAsync(ct);
    }

    /// <summary>
    /// Entrecomilla solo cuando hace falta y duplica las comillas internas.
    /// Un nombre de producto con coma es lo normal, no la excepción.
    /// </summary>
    private static string Escapar(string? valor)
    {
        var v = valor ?? string.Empty;
        return v.Contains(',') || v.Contains('"') || v.Contains('\n') || v.Contains('\r')
            ? $"\"{v.Replace("\"", "\"\"")}\""
            : v;
    }

    public sealed record FilaExportacion(
        string producto_sku, string producto_nombre, string categoria_nombre,
        string almacen_codigo, string almacen_nombre, string localizador,
        int cantidad_fisica, int cantidad_reservada, int cantidad_disponible, int cantidad_minima,
        bool es_existencia_baja, decimal producto_precio, string producto_estatus,
        DateTime actualizado_en);
}

/// <summary>
/// Autorización de la exportación.
///
/// El alcance de la prueba excluye autenticación, pero cat_usuarios SÍ tiene
/// rol. Sacar el catálogo completo con precios y valuación es una operación
/// distinta de mover una caja, así que se restringe a SUPERVISOR y SISTEMA.
/// Es la política más conservadora que el modelo actual permite expresar sin
/// inventar un sistema de permisos.
/// </summary>
public static class PermisoExportacion
{
    private static readonly string[] RolesAutorizados = ["SUPERVISOR", "SISTEMA"];

    public static async Task ExigirAsync(DbConnection conexion, long usuarioId, CancellationToken ct)
    {
        var usuario = await conexion.QuerySingleOrDefaultAsync<(string rol, bool es_activo)?>(
            new CommandDefinition("select rol, es_activo from wms.cat_usuarios where id = @Id",
                new { Id = usuarioId }, cancellationToken: ct));

        if (usuario is null || !usuario.Value.es_activo)
            throw new ExcepcionWms("WM014", 422, "El operador no existe o está inactivo.");

        if (!RolesAutorizados.Contains(usuario.Value.rol))
            throw new ExcepcionWms("WM017", 403,
                "Este operador no puede exportar inventario.",
                $"La exportación incluye precios y valuación; se limita a {string.Join(" y ", RolesAutorizados)}.");
    }
}
