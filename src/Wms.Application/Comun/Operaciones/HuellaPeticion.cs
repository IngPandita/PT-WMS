using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Wms.Application.Comun.Operaciones;

/// <summary>
/// Huella canonica de la INTENCION.
///
/// Regla normativa: el conjunto de campos debe ser superconjunto de las
/// columnas de ux_tbl_movimientos_inventario__operacion y NADA MAS. Incluir
/// un campo editable —el motivo, por ejemplo— haria que reenviar la misma
/// intencion con el texto corregido produjera WM015 permanente; el usuario,
/// al no poder avanzar, cerraria el modal y acunaria un id nuevo, que si se
/// aplicaria por segunda vez. Un hash demasiado amplio CAUSA la duplicacion
/// que pretende evitar.
/// </summary>
public static class HuellaPeticion
{
    public const string RutaAjuste          = "/api/inventario/ajustar";
    public const string RutaCrearOrden      = "/api/ordenes";
    public const string RutaConfirmarOrden  = "/api/ordenes/confirmar";
    public const string RutaEnviarOrden     = "/api/ordenes/enviar";
    public const string RutaCancelarOrden   = "/api/ordenes/cancelar";
    public const string RutaImportacion     = "/api/importacion";
    public const string RutaEstablecer      = "/api/inventario/establecer";
    public const string RutaRevertirMovimiento = "/api/inventario/movimientos/revertir";
    public const string RutaAltaCatalogo    = "/api/catalogos/alta";
    public const string RutaEditarCatalogo  = "/api/catalogos/editar";
    public const string RutaVigenciaCatalogo = "/api/catalogos/vigencia";

    /// <summary>Campos de la intencion por ruta. Todo lo demas se ignora.</summary>
    public static readonly IReadOnlyDictionary<string, string[]> CamposPorRuta =
        new Dictionary<string, string[]>
        {
            [RutaAjuste]         = ["almacen_id", "delta", "producto_id", "tipo_movimiento", "usuario_id"],
            // Las partidas entran como huella agregada: cambiar una cantidad es
            // una intencion distinta, pero reordenarlas no.
            [RutaCrearOrden]     = ["almacen_id", "cliente_id", "partidas", "usuario_id"],
            // El motivo de cancelacion queda FUERA, igual que el del ajuste.
            [RutaConfirmarOrden] = ["accion", "orden_id", "usuario_id"],
            [RutaEnviarOrden]    = ["accion", "orden_id", "usuario_id"],
            [RutaCancelarOrden]  = ["accion", "orden_id", "usuario_id"],
            [RutaImportacion]    = ["hash_archivo", "modo", "usuario_id"],
            // Ajuste a cantidad absoluta: la intencion es el OBJETIVO.
            [RutaEstablecer]     = ["almacen_id", "objetivo", "producto_id", "usuario_id"],
            // El motivo de la desactivacion queda fuera, como en el resto.
            [RutaRevertirMovimiento] = ["accion", "movimiento_id", "usuario_id"],
            [RutaAltaCatalogo]   = ["recurso", "usuario_id", "valores"],
            // La edicion identifica la fila y los valores nuevos. La version
            // esperada queda FUERA: reenviar la misma correccion es un
            // reintento, y el numero de version ya cambio en el primer intento.
            [RutaEditarCatalogo] = ["id", "recurso", "usuario_id", "valores"],
            // Activar y desactivar son intenciones distintas sobre la misma fila.
            [RutaVigenciaCatalogo] = ["id", "recurso", "usuario_id", "vigente"],
        };

    public static string Calcular(string claveRuta, IReadOnlyDictionary<string, object?> valores)
    {
        if (!CamposPorRuta.TryGetValue(claveRuta, out var campos))
            throw new InvalidOperationException(
                $"No hay conjunto de huella definido para '{claveRuta}'. " +
                "Toda ruta mutante debe declararlo explicitamente.");

        var objeto = new JsonObject();
        foreach (var campo in campos.OrderBy(c => c, StringComparer.Ordinal))
        {
            valores.TryGetValue(campo, out var valor);
            // Ausente, null y cadena vacia se normalizan al mismo valor, para
            // que un reintento con el campo omitido no cambie la huella.
            objeto[campo] = Normalizar(valor);
        }

        var json = objeto.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
    }

    /// <summary>
    /// Huella estable de un conjunto de partidas: se ordena por producto para
    /// que reordenar la captura no cuente como una intencion distinta.
    /// </summary>
    public static string HuellaPartidas(IEnumerable<(long ProductoId, int Cantidad)> partidas) =>
        string.Join("|", partidas.OrderBy(p => p.ProductoId).Select(p => $"{p.ProductoId}x{p.Cantidad}"));

    private static JsonNode? Normalizar(object? valor) => valor switch
    {
        null => JsonValue.Create("∅"),
        string s when string.IsNullOrWhiteSpace(s) => JsonValue.Create("∅"),
        string s => JsonValue.Create(s),
        bool b => JsonValue.Create(b),
        _ => JsonValue.Create(Convert.ToString(valor, System.Globalization.CultureInfo.InvariantCulture)),
    };
}
