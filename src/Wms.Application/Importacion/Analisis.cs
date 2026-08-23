using System.Globalization;
using System.Text;

namespace Wms.Application.Importacion;

/// <summary>Códigos estables. El frontend agrupa por ellos, así que son contrato.</summary>
public static class CodigoErrorImportacion
{
    public const string ColumnasInvalidas    = "COLUMNAS_INVALIDAS";
    public const string NombreRequerido      = "NOMBRE_REQUERIDO";
    public const string CategoriaInexistente = "CATEGORIA_INEXISTENTE";
    public const string AlmacenInexistente   = "ALMACEN_INEXISTENTE";
    public const string CantidadInvalida     = "CANTIDAD_INVALIDA";
    public const string PrecioInvalido       = "PRECIO_INVALIDO";
    public const string EstatusInvalido      = "ESTATUS_INVALIDO";
    public const string DuplicadoEnArchivo   = "DUPLICADO_EN_ARCHIVO";
    public const string SkuYaExiste          = "SKU_YA_EXISTE";
    public const string YaAplicado           = "YA_APLICADO";
    public const string FallaAlAplicar       = "FALLA_AL_APLICAR";
    /// <summary>El renglon exigia crear un producto y el operador no es SISTEMA.</summary>
    public const string PermisoAltaCatalogo  = "PERMISO_ALTA_CATALOGO";
}

public sealed record RenglonImportacion(
    int Numero,
    string CategoriaCodigo, string NombreProducto, string? Descripcion,
    decimal PrecioUnitario, string Estatus,
    string AlmacenCodigo, int CantidadInicial, int CantidadMinima,
    string CargaOriginalJson)
{
    /// <summary>Identidad de negocio del renglón dentro del archivo.</summary>
    public string Clave => $"{CategoriaCodigo}|{NombreProducto.ToLowerInvariant()}|{AlmacenCodigo}";
}

public sealed record RenglonInvalido(int Numero, string Codigo, string Mensaje, string CargaOriginalJson);

public sealed record AnalisisArchivo(
    IReadOnlyList<RenglonImportacion> Validos,
    IReadOnlyList<RenglonInvalido> Invalidos,
    int TotalRenglones);

/// <summary>
/// PRIMERA PASADA: valida el archivo entero en memoria y produce el reporte.
/// Solo después se aplica. Un archivo 100 % inválido nunca abre transacción.
/// </summary>
public static class AnalizadorArchivo
{
    private static readonly string[] EstatusValidos = ["ACTIVO", "INACTIVO", "DESCONTINUADO"];

    public static AnalisisArchivo Analizar(string contenido)
    {
        var validos = new List<RenglonImportacion>();
        var invalidos = new List<RenglonInvalido>();

        var lineas = contenido.Replace("\r\n", "\n").Replace('\r', '\n')
            .Split('\n', StringSplitOptions.None)
            .Select(l => l.TrimStart('﻿'))
            .ToList();

        while (lineas.Count > 0 && string.IsNullOrWhiteSpace(lineas[^1])) lineas.RemoveAt(lineas.Count - 1);
        if (lineas.Count == 0)
            return new AnalisisArchivo([], [new RenglonInvalido(0,
                CodigoErrorImportacion.ColumnasInvalidas, "El archivo está vacío.", "{}")], 1);

        var encabezado = Plantilla.LeerCampos(lineas[0]).Select(c => c.ToLowerInvariant()).ToList();
        if (!Plantilla.Columnas.SequenceEqual(encabezado))
            return new AnalisisArchivo([], [new RenglonInvalido(0,
                CodigoErrorImportacion.ColumnasInvalidas,
                $"El encabezado debe ser exactamente: {string.Join(", ", Plantilla.Columnas)}.",
                "{}")], 1);

        // La clave detecta duplicados DENTRO del archivo. Es distinto de un
        // duplicado contra la base: aquel puede ser una actualización legítima.
        var vistos = new Dictionary<string, int>();

        for (var i = 1; i < lineas.Count; i++)
        {
            var numero = i;                       // 1 = primer renglón de datos
            if (string.IsNullOrWhiteSpace(lineas[i])) continue;

            var campos = Plantilla.LeerCampos(lineas[i]);
            var carga = CargaJson(campos);

            if (campos.Count != Plantilla.Columnas.Length)
            {
                invalidos.Add(new RenglonInvalido(numero, CodigoErrorImportacion.ColumnasInvalidas,
                    $"Se esperaban {Plantilla.Columnas.Length} columnas y llegaron {campos.Count}.", carga));
                continue;
            }

            var categoria = campos[0].ToUpperInvariant();
            var nombre = campos[1];
            var descripcion = string.IsNullOrWhiteSpace(campos[2]) ? null : campos[2];
            var estatus = string.IsNullOrWhiteSpace(campos[4]) ? "ACTIVO" : campos[4].ToUpperInvariant();
            var almacen = campos[5].ToUpperInvariant();

            if (string.IsNullOrWhiteSpace(nombre) || nombre.Trim().Length < 2)
            {
                invalidos.Add(new RenglonInvalido(numero, CodigoErrorImportacion.NombreRequerido,
                    "El nombre del producto es obligatorio (mínimo 2 caracteres).", carga));
                continue;
            }
            if (!decimal.TryParse(campos[3], NumberStyles.Number, CultureInfo.InvariantCulture, out var precio)
                || precio < 0)
            {
                invalidos.Add(new RenglonInvalido(numero, CodigoErrorImportacion.PrecioInvalido,
                    $"'{campos[3]}' no es un precio válido (use punto decimal y no negativos).", carga));
                continue;
            }
            if (!EstatusValidos.Contains(estatus))
            {
                invalidos.Add(new RenglonInvalido(numero, CodigoErrorImportacion.EstatusInvalido,
                    $"'{campos[4]}' no es un estatus válido ({string.Join('/', EstatusValidos)}).", carga));
                continue;
            }
            if (!int.TryParse(campos[6], out var cantidad) || cantidad < 0)
            {
                invalidos.Add(new RenglonInvalido(numero, CodigoErrorImportacion.CantidadInvalida,
                    $"'{campos[6]}' no es una cantidad válida (entero no negativo).", carga));
                continue;
            }
            if (!int.TryParse(string.IsNullOrWhiteSpace(campos[7]) ? "0" : campos[7], out var minima)
                || minima < 0)
            {
                invalidos.Add(new RenglonInvalido(numero, CodigoErrorImportacion.CantidadInvalida,
                    $"'{campos[7]}' no es un mínimo válido (entero no negativo).", carga));
                continue;
            }

            var renglon = new RenglonImportacion(numero, categoria, nombre.Trim(), descripcion,
                precio, estatus, almacen, cantidad, minima, carga);

            if (vistos.TryGetValue(renglon.Clave, out var primero))
            {
                invalidos.Add(new RenglonInvalido(numero, CodigoErrorImportacion.DuplicadoEnArchivo,
                    $"El mismo producto y almacén ya aparece en el renglón {primero}. " +
                    "Sume las cantidades en un solo renglón.", carga));
                continue;
            }

            vistos[renglon.Clave] = numero;
            validos.Add(renglon);
        }

        return new AnalisisArchivo(validos, invalidos, validos.Count + invalidos.Count);
    }

    private static string CargaJson(IReadOnlyList<string> campos)
    {
        var sb = new StringBuilder("{");
        for (var i = 0; i < Plantilla.Columnas.Length; i++)
        {
            if (i > 0) sb.Append(',');
            var valor = i < campos.Count ? campos[i] : "";
            sb.Append('"').Append(Plantilla.Columnas[i]).Append("\":\"")
              .Append(valor.Replace("\\", "\\\\").Replace("\"", "\\\"")).Append('"');
        }
        return sb.Append('}').ToString();
    }
}
