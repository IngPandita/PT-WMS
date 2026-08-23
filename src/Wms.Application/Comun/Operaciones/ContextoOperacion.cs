namespace Wms.Application.Comun.Operaciones;

/// <summary>
/// Identidad de la INTENCIÓN del usuario, tomada de los encabezados HTTP.
/// El id_operacion lo acuña el cliente una sola vez y lo reutiliza en cada
/// reenvío; el prefijo de operador es obligatorio y la base lo verifica.
/// </summary>
public sealed record ContextoOperacion(string IdOperacion, long UsuarioId, string Alcance, string Ruta)
{
    /// <summary>
    /// El id que viaja a la base incluye el operador como primer segmento.
    /// Sin ese espacio de nombres, dos operadores con el mismo id y cuerpo
    /// idéntico colisionarían y el segundo recibiría la respuesta del primero.
    /// </summary>
    public string IdOperacionCompleto =>
        IdOperacion.StartsWith(UsuarioId + ":", StringComparison.Ordinal)
            ? IdOperacion
            : $"{UsuarioId}:{IdOperacion}";
}
