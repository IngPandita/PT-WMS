using Dapper;
using Microsoft.Extensions.Caching.Memory;
using Npgsql;
using Wms.Application.Abstracciones;
using Wms.Application.Comun.Sku;

namespace Wms.Infrastructure.Persistencia;

/// <summary>
/// Carga la regla ACTIVA desde wms.cat_reglas_sku. El patrón no vive en el
/// binario: motor y API comparten una sola fuente de verdad, así que cambiar
/// la regla no exige recompilar. La caché es corta a propósito — un minuto —
/// para que un cambio de regla se propague sin reiniciar el servicio.
/// </summary>
public sealed class RepositorioReglasSku(string cadena, IMemoryCache cache) : IRepositorioReglasSku
{
    private const string Clave = "wms:regla-sku-activa";

    public async Task<AnalizadorSku> ObtenerAnalizadorAsync(CancellationToken ct)
    {
        if (cache.TryGetValue<AnalizadorSku>(Clave, out var enCache) && enCache is not null)
            return enCache;

        await using var conexion = new NpgsqlConnection(cadena);
        await conexion.OpenAsync(ct);

        var fila = await conexion.QuerySingleOrDefaultAsync<FilaRegla>(new CommandDefinition(
            "select id, nombre, separador, patron_prefijo, longitud_consecutivo, patron_completo " +
            "  from wms.cat_reglas_sku where es_activo", cancellationToken: ct));

        if (fila is null)
            throw new InvalidOperationException(
                "No hay ninguna regla de SKU activa en wms.cat_reglas_sku.");

        var analizador = new AnalizadorSku(new ReglaSku(
            fila.id, fila.nombre, fila.separador, fila.patron_prefijo,
            fila.longitud_consecutivo, fila.patron_completo));

        cache.Set(Clave, analizador, TimeSpan.FromMinutes(1));
        return analizador;
    }

    private sealed record FilaRegla(
        long id, string nombre, string separador, string patron_prefijo,
        int longitud_consecutivo, string patron_completo);
}
