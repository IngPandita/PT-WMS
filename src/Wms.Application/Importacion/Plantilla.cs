using System.Text;

namespace Wms.Application.Importacion;

/// <summary>
/// Plantilla descargable y su lector.
///
/// El SKU NO va en la plantilla: lo acuna el servidor. Eso elimina de raiz la
/// colision de SKUs entre archivos preparados por distintas personas, que es
/// el modo de falla mas probable de una carga masiva con identificadores
/// capturados a mano.
/// </summary>
public static class Plantilla
{
    public static readonly string[] Columnas =
    [
        "categoria_codigo", "nombre_producto", "descripcion", "precio_unitario",
        "estatus", "almacen_codigo", "cantidad_inicial", "cantidad_minima"
    ];

    public static byte[] GenerarCsv()
    {
        var sb = new StringBuilder();
        sb.AppendLine(string.Join(',', Columnas));
        sb.AppendLine("ELEC,Cable HDMI 2 m,Cable de alta velocidad,189.50,ACTIVO,ALM-NTE,120,20");
        sb.AppendLine("ELEC,\"Hub USB, 4 puertos\",\"Con carcasa de aluminio\",349.00,ACTIVO,ALM-SUR,60,10");
        sb.AppendLine("HOGA,Juego de sartenes,,899.00,ACTIVO,ALM-CTR,25,5");
        // BOM para que Excel en es-MX no rompa los acentos al abrirlo.
        return Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(sb.ToString())).ToArray();
    }

    /// <summary>
    /// Lector CSV minimo pero correcto: respeta campos entrecomillados con
    /// comas y comillas escapadas (""), que aparecen en cuanto alguien captura
    /// una descripcion real.
    /// </summary>
    public static List<string> LeerCampos(string linea)
    {
        var campos = new List<string>();
        var actual = new StringBuilder();
        var entreComillas = false;

        for (var i = 0; i < linea.Length; i++)
        {
            var c = linea[i];
            if (entreComillas)
            {
                if (c == '"')
                {
                    if (i + 1 < linea.Length && linea[i + 1] == '"') { actual.Append('"'); i++; }
                    else entreComillas = false;
                }
                else actual.Append(c);
            }
            else if (c == '"') entreComillas = true;
            else if (c == ',') { campos.Add(actual.ToString().Trim()); actual.Clear(); }
            else actual.Append(c);
        }
        campos.Add(actual.ToString().Trim());
        return campos;
    }
}
