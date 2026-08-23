using System.Data;
using Dapper;
using FluentValidation;
using MediatR;
using Wms.Application.Comun.Operaciones;
using Wms.Application.Consultas;
using Wms.Domain.Errores;

namespace Wms.Application.Catalogos;

public sealed record ComandoAltaCatalogo(string Recurso, Dictionary<string, string?> Campos)
    : IRequest<Fila>;

/// <summary>
/// Cómo se expresa la vigencia en un catálogo. Cuatro de los cinco usan un
/// booleano `es_activo`; `cat_productos` usa `estatus` con tres valores porque
/// distinguir INACTIVO de DESCONTINUADO tiene sentido de negocio. La
/// excepción está declarada aquí en vez de repartida por el código.
/// </summary>
public sealed record VigenciaCatalogo(string Columna, string TipoSql, string Vigente, string NoVigente);

/// <summary>
/// Definición de un catálogo manipulado desde la API: qué columnas acepta al
/// dar de alta, cuáles se pueden corregir después y cómo se valida cada una.
///
/// Las listas son EXPLÍCITAS por diseño. Un alta o una edición genéricas que
/// reflejaran las columnas de la tabla dejarían escribir campos que el motor
/// calcula —el SKU acuñado, el consecutivo, los sellos de baja, la versión de
/// concurrencia— y serían justo el endpoint genérico que puede usarse para
/// saltarse una regla.
/// </summary>
public sealed record DefinicionCatalogo(
    string Tabla,
    string[] Obligatorios,
    string[] Opcionales,
    string[] Editables,
    VigenciaCatalogo Vigencia,
    Dictionary<string, (string Patron, string Mensaje)> Formatos);

public sealed class ValidadorAltaCatalogo : AbstractValidator<ComandoAltaCatalogo>
{
    public ValidadorAltaCatalogo()
    {
        RuleFor(c => c.Recurso).Must(CatalogosPermitidos.Existe)
            .WithMessage(c => $"'{c.Recurso}' no es un catálogo con alta habilitada. " +
                              $"Disponibles: {string.Join(", ", CatalogosPermitidos.Nombres)}.");

        RuleFor(c => c).Custom((cmd, ctx) =>
        {
            if (!CatalogosPermitidos.Existe(cmd.Recurso)) return;
            var def = CatalogosPermitidos.Obtener(cmd.Recurso);

            foreach (var campo in def.Obligatorios)
                if (!cmd.Campos.TryGetValue(campo, out var v) || string.IsNullOrWhiteSpace(v))
                    ctx.AddFailure(campo, $"'{campo}' es obligatorio.");

            var admitidos = def.Obligatorios.Concat(def.Opcionales).ToHashSet();
            foreach (var campo in cmd.Campos.Keys)
                if (!admitidos.Contains(campo))
                    ctx.AddFailure(campo,
                        $"'{campo}' no se puede capturar en este catálogo. " +
                        "Las columnas derivadas las calcula el motor.");

            foreach (var (campo, mensaje) in CatalogosPermitidos.RevisarFormatos(def, cmd.Campos))
                ctx.AddFailure(campo, mensaje);
        });
    }
}

public static class CatalogosPermitidos
{
    // El SKU, el consecutivo, la versión de concurrencia y los sellos de baja
    // NO aparecen en ninguna lista: los calcula el motor, y capturarlos a mano
    // rompería la acuñación o falsearía la auditoría.
    private static readonly VigenciaCatalogo PorBooleano = new("es_activo", "boolean", "true", "false");

    private static readonly Dictionary<string, DefinicionCatalogo> Definiciones = new()
    {
        // El código es el prefijo del SKU. Se deja EDITABLE a propósito: si la
        // categoría todavía no ha acuñado ningún producto, corregir un código
        // recién capturado es legítimo. En cuanto existe un producto, la clave
        // foránea sku_prefijo -> codigo (on update restrict) lo impide en el
        // motor. La regla no la decide la API.
        ["categorias"] = new("wms.cat_categorias",
            ["codigo", "nombre"], ["descripcion"],
            ["codigo", "nombre", "descripcion"], PorBooleano,
            new() { ["codigo"] = ("^[A-Z]{4}$", "El código debe ser exactamente 4 letras mayúsculas; es el prefijo del SKU.") }),

        // El código del almacén es un LOCALIZADOR: no forma parte del SKU y
        // nada lo referencia por valor, así que reubicar un almacén es editar
        // su código.
        ["almacenes"] = new("wms.cat_almacenes",
            ["codigo", "nombre"], ["direccion"],
            ["codigo", "nombre", "direccion"], PorBooleano,
            new() { ["codigo"] = ("^ALM-[A-Z0-9]{3}$", "El código debe tener la forma ALM-XXX (longitud fija).") }),

        // El código del cliente es generado y opaco: no incorpora el nombre
        // comercial, que sí cambia. Por eso el nombre se edita y el código no.
        ["clientes"] = new("wms.cat_clientes",
            ["nombre"], ["correo", "telefono"],
            ["nombre", "correo", "telefono"], PorBooleano,
            new() { ["correo"] = (@"^[^@\s]+@[^@\s]+\.[^@\s]+$", "El correo no tiene un formato válido.") }),

        // 'rol' figura como editable, pero el motor sólo se lo permite al
        // operador 1: el rol gobierna el permiso de exportación y dejarlo
        // abierto convertiría la edición en una vía de ascenso (WM021).
        ["usuarios"] = new("wms.cat_usuarios",
            ["nombre"], ["correo", "rol"],
            ["nombre", "correo", "rol"], PorBooleano,
            new() { ["rol"] = ("^(OPERADOR|SUPERVISOR|SISTEMA)$", "El rol debe ser OPERADOR, SUPERVISOR o SISTEMA.") }),

        // categoria_id es editable: recategorizar NO reescribe el SKU, que
        // quedó congelado en sku_prefijo + sku_consecutivo al acuñarse.
        ["productos"] = new("wms.cat_productos",
            ["categoria_id", "nombre"], ["descripcion", "precio_unitario"],
            ["categoria_id", "nombre", "descripcion", "precio_unitario"],
            new VigenciaCatalogo("estatus", "text", "ACTIVO", "INACTIVO"),
            new() {
                ["categoria_id"]    = (@"^\d+$", "La categoría debe ser un identificador numérico."),
                ["precio_unitario"] = (@"^\d+(\.\d{1,2})?$", "El precio debe ser un número no negativo con hasta dos decimales."),
            }),
    };

    public static IEnumerable<string> Nombres => Definiciones.Keys;
    public static bool Existe(string recurso) => Definiciones.ContainsKey(recurso);
    public static DefinicionCatalogo Obtener(string recurso) => Definiciones[recurso];

    /// <summary>
    /// Revisa las reglas de formato de los campos presentes y devuelve los
    /// incumplimientos. Devuelve en vez de acumular porque la usan dos
    /// validadores distintos —alta y edicion— sobre comandos distintos.
    /// </summary>
    public static IEnumerable<(string Campo, string Mensaje)> RevisarFormatos(
        DefinicionCatalogo def, IReadOnlyDictionary<string, string?> campos)
    {
        foreach (var (campo, regla) in def.Formatos)
            if (campos.TryGetValue(campo, out var v) && !string.IsNullOrWhiteSpace(v)
                && !System.Text.RegularExpressions.Regex.IsMatch(v, regla.Patron))
                yield return (campo, regla.Mensaje);
    }

    /// <summary>Los campos llegan como texto; se convierten al tipo de la columna.</summary>
    public static object? Convertir(string columna, string? valor)
    {
        if (string.IsNullOrWhiteSpace(valor)) return null;
        return columna switch
        {
            "categoria_id"    => long.Parse(valor),
            "precio_unitario" => decimal.Parse(valor, System.Globalization.CultureInfo.InvariantCulture),
            _ => valor.Trim(),
        };
    }
}

/// <summary>
/// Alta en catálogos.
///
/// La restricción a usuario 1 la impone el trigger
/// a_trg_cat_*__alta_solo_sistema en el MOTOR, no esta clase. Aquí solo se
/// comprueba antes para devolver un 403 legible en vez de dejar que salte un
/// WM020 crudo; si alguien llamara por otra vía, el motor lo detendría igual.
/// </summary>
public sealed class ManejadorAltaCatalogo(EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<ComandoAltaCatalogo, Fila>
{
    public const long UsuarioSistema = 1;

    public async Task<Fila> Handle(ComandoAltaCatalogo cmd, CancellationToken ct)
    {
        if (contexto.UsuarioId != UsuarioSistema)
            throw new ExcepcionWms("WM020", 403,
                "Solo el usuario SISTEMA puede dar de alta registros en catálogos.",
                "La restricción también se aplica en la base de datos: llamar al endpoint " +
                "directamente con otro operador tampoco funciona.");

        var def = CatalogosPermitidos.Obtener(cmd.Recurso);
        var columnas = cmd.Campos
            .Where(p => !string.IsNullOrWhiteSpace(p.Value))
            .Select(p => p.Key).OrderBy(c => c, StringComparer.Ordinal).ToList();

        var intencion = new Dictionary<string, object?>
        {
            ["recurso"]    = cmd.Recurso,
            ["usuario_id"] = contexto.UsuarioId,
            // La huella cubre los valores capturados: reenviar la misma alta es
            // un reintento; cambiar un valor es otra intención.
            ["valores"]    = string.Join("|", columnas.Select(c => $"{c}={cmd.Campos[c]}")),
        };

        var r = await ejecutor.EjecutarAsync(contexto, HuellaPeticion.RutaAltaCatalogo, intencion,
            async (conexion, tx, token) =>
            {
                // El contexto de operador debe estar fijado en la MISMA
                // transacción: es lo que lee el trigger del motor.
                await conexion.ExecuteAsync(new CommandDefinition(
                    "select set_config('wms.ctx_usuario_id', @Usuario, true)",
                    new { Usuario = contexto.UsuarioId.ToString() },
                    transaction: tx, cancellationToken: token));

                var sql = $"insert into {def.Tabla} ({string.Join(", ", columnas)}) " +
                          $"values ({string.Join(", ", columnas.Select(c => "@" + c))}) returning *";

                var parametros = new DynamicParameters();
                foreach (var c in columnas) parametros.Add(c, CatalogosPermitidos.Convertir(c, cmd.Campos[c]));

                var fila = await conexion.QuerySingleAsync(new CommandDefinition(
                    sql, parametros, transaction: tx, cancellationToken: token));
                return Fila.Desde((IDictionary<string, object>)fila);
            }, ct);

        return r.Valor;
    }
}
