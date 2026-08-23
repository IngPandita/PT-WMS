namespace Wms.Application.Comun.Sku;

/// <summary>Regla activa, cargada desde wms.cat_reglas_sku.</summary>
public sealed record ReglaSku(
    long Id, string Nombre, string Separador,
    string PatronPrefijo, int LongitudConsecutivo, string PatronCompleto);

public sealed record ResultadoAnalisisSku(bool EsValido, string? Prefijo, int? Consecutivo, string? Motivo)
{
    public static ResultadoAnalisisSku Valido(string prefijo, int consecutivo) =>
        new(true, prefijo, consecutivo, null);

    public static ResultadoAnalisisSku Invalido(string motivo) => new(false, null, null, motivo);
}
