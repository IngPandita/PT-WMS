using System.Text.RegularExpressions;

namespace Wms.Application.Comun.Sku;

/// <summary>
/// Analiza un SKU contra la regla ACTIVA de la base. El patron no esta
/// compilado en el binario: vive en wms.cat_reglas_sku para que el motor y
/// la API compartan una sola fuente de verdad. Cambiar la regla no exige
/// recompilar.
/// </summary>
public sealed class AnalizadorSku
{
    private readonly Regex _patron;

    public AnalizadorSku(ReglaSku regla)
    {
        Regla = regla;
        _patron = new Regex(regla.PatronCompleto,
            RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture,
            TimeSpan.FromMilliseconds(100));
    }

    public ReglaSku Regla { get; }

    public ResultadoAnalisisSku Analizar(string? sku)
    {
        if (string.IsNullOrWhiteSpace(sku))
            return ResultadoAnalisisSku.Invalido("El SKU viene vacio.");

        if (!_patron.IsMatch(sku))
            return ResultadoAnalisisSku.Invalido(
                $"'{sku}' no cumple la regla activa '{Regla.Nombre}' ({Regla.PatronCompleto}).");

        var partes = sku.Split(Regla.Separador);
        if (partes.Length != 2)
            return ResultadoAnalisisSku.Invalido(
                $"'{sku}' no tiene exactamente dos segmentos separados por '{Regla.Separador}'.");

        // El patron ya garantizo que el segundo segmento son digitos.
        return ResultadoAnalisisSku.Valido(partes[0], int.Parse(partes[1]));
    }
}
