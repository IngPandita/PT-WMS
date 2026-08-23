namespace Wms.Domain.Errores;

/// <summary>
/// Catálogo de errores de negocio. Los SQLSTATE de la clase WM los levanta
/// PL/pgSQL; este mapa es el ÚNICO lugar donde se traducen a HTTP, de modo
/// que la API nunca hace string-matching sobre mensajes en español.
/// </summary>
public static class CodigoWms
{
    public sealed record Definicion(string Codigo, int Http, string Titulo, bool Reintentable);

    private static readonly Dictionary<string, Definicion> Mapa = new()
    {
        ["WM001"] = new("WM001", 409, "Transición de orden inválida", false),
        ["WM002"] = new("WM002", 422, "Existencia insuficiente", false),
        ["WM003"] = new("WM003", 409, "El SKU es inmutable", false),
        ["WM004"] = new("WM004", 409, "SKU duplicado", false),
        ["WM005"] = new("WM005", 422, "Sin inventario en el almacén", false),
        ["WM006"] = new("WM006", 409, "La bitácora es inmutable", false),
        ["WM007"] = new("WM007", 409, "La orden no es editable", false),
        ["WM008"] = new("WM008", 409, "Conflicto de concurrencia", false),
        ["WM009"] = new("WM009", 422, "Formato de SKU inválido", false),
        ["WM010"] = new("WM010", 409, "El total es derivado", false),
        ["WM011"] = new("WM011", 422, "La orden no tiene partidas", false),
        ["WM012"] = new("WM012", 400, "Argumento inválido", false),
        ["WM013"] = new("WM013", 409, "Operación duplicada en curso", false),
        ["WM014"] = new("WM014", 422, "Usuario inactivo o no declarado", false),
        ["WM015"] = new("WM015", 409, "La operación llegó con una carga distinta", false),
        ["WM016"] = new("WM016", 409, "La operación pertenece a otro operador", false),
        ["WM017"] = new("WM017", 403, "El operador no tiene permiso para esta acción", false),
        ["WM018"] = new("WM018", 403, "Solo el usuario SISTEMA puede desactivar movimientos", false),
        ["WM019"] = new("WM019", 409, "El movimiento no admite desactivación", false),
        ["WM020"] = new("WM020", 403, "Solo el usuario SISTEMA puede dar de alta en catálogos", false),
        ["WM021"] = new("WM021", 403, "Solo el usuario SISTEMA puede cambiar el rol de un operador", false),
        ["WM022"] = new("WM022", 409, "El operador SISTEMA no se puede desactivar", false),
        ["WM023"] = new("WM023", 409, "El registro ya tenía esa vigencia", false),

        // SQLSTATE estándar que sí nos importan.
        ["23505"] = new("23505", 409, "Violación de unicidad", false),
        ["23503"] = new("23503", 409, "Violación de integridad referencial", false),
        ["23514"] = new("23514", 422, "Violación de una restricción de dominio", false),
        ["P0002"] = new("P0002", 404, "No encontrado", false),
        ["57014"] = new("57014", 499, "Consulta cancelada por el cliente", false),
        ["40001"] = new("40001", 409, "Conflicto de serialización", true),
        ["40P01"] = new("40P01", 409, "Interbloqueo detectado", true),
        ["55P03"] = new("55P03", 423, "Recurso bloqueado", true),
    };

    public static Definicion Resolver(string? sqlState) =>
        sqlState is not null && Mapa.TryGetValue(sqlState, out var d)
            ? d
            : new Definicion(sqlState ?? "DESCONOCIDO", 500, "Error interno", false);

    /// <summary>SQLSTATE que Polly puede reintentar sin cambiar el id_operacion.</summary>
    public static bool EsTransitorio(string? sqlState) => Resolver(sqlState).Reintentable;
}
