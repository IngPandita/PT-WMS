namespace Wms.Domain.Errores;

/// <summary>Error de negocio ya traducido, listo para ProblemDetails.</summary>
public sealed class ExcepcionWms(string codigo, int http, string mensaje, string? detalle = null)
    : Exception(mensaje)
{
    public string Codigo { get; } = codigo;
    public int Http { get; } = http;
    public string? Detalle { get; } = detalle;
}
