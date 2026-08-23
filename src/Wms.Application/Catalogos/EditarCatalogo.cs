using System.Data;
using System.Data.Common;
using Dapper;
using FluentValidation;
using MediatR;
using Wms.Application.Comun.Operaciones;
using Wms.Application.Consultas;
using Wms.Domain.Errores;

namespace Wms.Application.Catalogos;

public sealed record ComandoEditarCatalogo(
    string Recurso, long Id, Dictionary<string, string?> Campos, long VersionEsperada) : IRequest<Fila>;

public sealed record ComandoCambiarVigenciaCatalogo(
    string Recurso, long Id, bool Vigente) : IRequest<Fila>;

// =====================================================================
//  Validación
// =====================================================================

public sealed class ValidadorEditarCatalogo : AbstractValidator<ComandoEditarCatalogo>
{
    public ValidadorEditarCatalogo()
    {
        RuleFor(c => c.Recurso).Must(CatalogosPermitidos.Existe)
            .WithMessage(c => $"'{c.Recurso}' no es un catálogo editable. " +
                              $"Disponibles: {string.Join(", ", CatalogosPermitidos.Nombres)}.");

        RuleFor(c => c.Id).GreaterThan(0);

        // La versión es obligatoria, no opcional. Sin ella la edición sería un
        // «el último gana» silencioso: dos operadores corrigiendo el mismo
        // cliente y uno de los dos cambios desaparece sin que nadie se entere.
        RuleFor(c => c.VersionEsperada).GreaterThan(0)
            .WithMessage("Falta la versión de concurrencia del registro que se está editando.");

        RuleFor(c => c.Campos).Must(c => c.Count > 0)
            .WithMessage("No se envió ningún campo que corregir.");

        RuleFor(c => c).Custom((cmd, ctx) =>
        {
            if (!CatalogosPermitidos.Existe(cmd.Recurso)) return;
            var def = CatalogosPermitidos.Obtener(cmd.Recurso);

            foreach (var campo in cmd.Campos.Keys)
                if (!def.Editables.Contains(campo))
                    ctx.AddFailure(campo, EsCapturable(def, campo)
                        ? $"'{campo}' se define al dar de alta y después no se corrige."
                        : $"'{campo}' no es un campo editable de este catálogo. " +
                          "Las columnas derivadas las calcula el motor.");

            // Un obligatorio presente no se puede vaciar: la columna es NOT NULL
            // y el motor lo rechazaría con un error mucho menos legible.
            foreach (var campo in def.Obligatorios)
                if (cmd.Campos.TryGetValue(campo, out var v) && string.IsNullOrWhiteSpace(v))
                    ctx.AddFailure(campo, $"'{campo}' no se puede dejar vacío.");

            foreach (var (campo, mensaje) in CatalogosPermitidos.RevisarFormatos(def, cmd.Campos))
                ctx.AddFailure(campo, mensaje);
        });
    }

    private static bool EsCapturable(DefinicionCatalogo def, string campo) =>
        def.Obligatorios.Contains(campo) || def.Opcionales.Contains(campo);
}

public sealed class ValidadorCambiarVigenciaCatalogo : AbstractValidator<ComandoCambiarVigenciaCatalogo>
{
    public ValidadorCambiarVigenciaCatalogo()
    {
        RuleFor(c => c.Recurso).Must(CatalogosPermitidos.Existe)
            .WithMessage(c => $"'{c.Recurso}' no es un catálogo conocido.");
        RuleFor(c => c.Id).GreaterThan(0);
    }
}

// =====================================================================
//  Edición
// =====================================================================

/// <summary>
/// Corrección de un registro de catálogo.
///
/// A diferencia del alta, editar NO exige ser el operador 1: lo exige el
/// motor sólo para el alta, y aquí no se inventa una política distinta de la
/// que la base impone. La asimetría está documentada en la especificación
/// (§3.11); lo que sí se conserva es que toda mutación lleve operador,
/// operación e idempotencia.
///
/// Lo que el motor sigue defendiendo por su cuenta, y esta clase no repite:
///   · cambiar el código de una categoría con productos acuñados -> 23503
///   · cambiar el SKU de un producto                             -> WM003
///   · cambiar el rol de un operador sin ser el 1                -> WM021
/// </summary>
public sealed class ManejadorEditarCatalogo(EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<ComandoEditarCatalogo, Fila>
{
    public async Task<Fila> Handle(ComandoEditarCatalogo cmd, CancellationToken ct)
    {
        var def = CatalogosPermitidos.Obtener(cmd.Recurso);
        var columnas = cmd.Campos.Keys.OrderBy(c => c, StringComparer.Ordinal).ToList();

        var intencion = new Dictionary<string, object?>
        {
            ["id"]         = cmd.Id,
            ["recurso"]    = cmd.Recurso,
            ["usuario_id"] = contexto.UsuarioId,
            ["valores"]    = string.Join("|", columnas.Select(c => $"{c}={cmd.Campos[c]}")),
        };

        var r = await ejecutor.EjecutarAsync(contexto, HuellaPeticion.RutaEditarCatalogo, intencion,
            async (conexion, tx, token) =>
            {
                await FijarOperadorAsync(conexion, tx, contexto.UsuarioId, token);

                var asignaciones = string.Join(", ", columnas.Select(c => $"{c} = @{c}"));
                var parametros = new DynamicParameters();
                foreach (var c in columnas) parametros.Add(c, CatalogosPermitidos.Convertir(c, cmd.Campos[c]));
                parametros.Add("Id", cmd.Id);
                parametros.Add("Version", cmd.VersionEsperada);

                var fila = await conexion.QuerySingleOrDefaultAsync(new CommandDefinition(
                    $"update {def.Tabla} set {asignaciones} " +
                    " where id = @Id and version_concurrencia = @Version returning *",
                    parametros, transaction: tx, cancellationToken: token));

                // Cero filas: o no existe, o alguien más ya lo editó. Son dos
                // respuestas distintas para el usuario, así que se distinguen.
                if (fila is null)
                    throw await DiagnosticarAsync(conexion, tx, def, cmd.Id, cmd.VersionEsperada, token);

                return Fila.Desde((IDictionary<string, object>)fila);
            }, ct);

        return r.Valor;
    }

    private static async Task FijarOperadorAsync(DbConnection c, DbTransaction tx, long usuarioId, CancellationToken ct) =>
        await c.ExecuteAsync(new CommandDefinition(
            "select set_config('wms.ctx_usuario_id', @Usuario, true)",
            new { Usuario = usuarioId.ToString() }, transaction: tx, cancellationToken: ct));

    /// <summary>Cero filas actualizadas tiene dos causas, y no dan el mismo consejo.</summary>
    private static async Task<ExcepcionWms> DiagnosticarAsync(DbConnection c, DbTransaction tx,
        DefinicionCatalogo def, long id, long versionEsperada, CancellationToken ct)
    {
        var actual = await c.QuerySingleOrDefaultAsync<long?>(new CommandDefinition(
            $"select version_concurrencia from {def.Tabla} where id = @Id",
            new { Id = id }, transaction: tx, cancellationToken: ct));

        if (actual is null)
            return new ExcepcionWms("P0002", 404,
                "El registro no existe.",
                $"No hay ningún registro con id {id} en este catálogo.");

        return new ExcepcionWms("WM008", 409,
            "Alguien más modificó este registro.",
            $"Se esperaba la versión {versionEsperada} y la actual es {actual}. " +
            "Vuelva a cargar el registro para no pisar el cambio del otro operador.");
    }
}

// =====================================================================
//  Alta y baja lógica
// =====================================================================

/// <summary>
/// Cambio de vigencia: baja lógica y su reverso.
///
/// Nunca borra. `fn_sellar_baja_logica` estampa quién y cuándo dentro de la
/// misma transacción, leyendo el operador del contexto de sesión, y reactivar
/// NO limpia ese sello: la baja ocurrió y su rastro sobrevive.
///
/// El motor defiende aparte que el operador 1 no se pueda desactivar (WM022):
/// es el único autorizado a dar de alta en catálogos, y darlo de baja dejaría
/// el sistema sin nadie capaz de crear uno.
/// </summary>
public sealed class ManejadorCambiarVigenciaCatalogo(EjecutorIdempotente ejecutor, ContextoOperacion contexto)
    : IRequestHandler<ComandoCambiarVigenciaCatalogo, Fila>
{
    public async Task<Fila> Handle(ComandoCambiarVigenciaCatalogo cmd, CancellationToken ct)
    {
        var def = CatalogosPermitidos.Obtener(cmd.Recurso);
        var destino = cmd.Vigente ? def.Vigencia.Vigente : def.Vigencia.NoVigente;

        var intencion = new Dictionary<string, object?>
        {
            ["id"]         = cmd.Id,
            ["recurso"]    = cmd.Recurso,
            ["usuario_id"] = contexto.UsuarioId,
            ["vigente"]    = cmd.Vigente,
        };

        var r = await ejecutor.EjecutarAsync(contexto, HuellaPeticion.RutaVigenciaCatalogo, intencion,
            async (conexion, tx, token) =>
            {
                await conexion.ExecuteAsync(new CommandDefinition(
                    "select set_config('wms.ctx_usuario_id', @Usuario, true)",
                    new { Usuario = contexto.UsuarioId.ToString() },
                    transaction: tx, cancellationToken: token));

                // El row lock evita que dos operadores lean «vigente» a la vez
                // y ambos crean que fueron ellos quienes lo desactivaron.
                var estado = await conexion.QuerySingleOrDefaultAsync<string?>(new CommandDefinition(
                    $"select {def.Vigencia.Columna}::text from {def.Tabla} where id = @Id for update",
                    new { Id = cmd.Id }, transaction: tx, cancellationToken: token));

                if (estado is null)
                    throw new ExcepcionWms("P0002", 404, "El registro no existe.",
                        $"No hay ningún registro con id {cmd.Id} en este catálogo.");

                if (string.Equals(estado, destino, StringComparison.OrdinalIgnoreCase))
                    throw new ExcepcionWms("WM023", 409,
                        cmd.Vigente ? "El registro ya estaba vigente." : "El registro ya estaba dado de baja.",
                        "Otro operador pudo haberse adelantado; vuelva a cargar la lista.");

                var fila = await conexion.QuerySingleAsync(new CommandDefinition(
                    // El valor viaja como texto y se convierte en SQL: es_activo es
                    // booleano y estatus es texto, y un parametro sin tipo declarado
                    // deja al driver adivinar.
                    $"update {def.Tabla} set {def.Vigencia.Columna} = @Destino::{def.Vigencia.TipoSql} " +
                    " where id = @Id returning *",
                    new { Destino = destino, Id = cmd.Id }, transaction: tx, cancellationToken: token));

                return Fila.Desde((IDictionary<string, object>)fila);
            }, ct);

        return r.Valor;
    }
}
