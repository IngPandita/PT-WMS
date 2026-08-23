using System.Data.Common;
using Dapper;
using Npgsql;
using Wms.Application.Abstracciones;
using Wms.Application.Comun.Operaciones;

namespace Wms.Infrastructure.Persistencia;

public sealed class FabricaConexion(string cadena) : IFabricaConexion
{
    public async Task<DbConnection> AbrirAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(cadena);
        await conexion.OpenAsync(ct);
        return conexion;
    }
}

/// <summary>
/// Fases 0 y 2 del protocolo de idempotencia. Ambas abren su PROPIA conexión
/// y confirman de inmediato, por dos razones distintas y ambas obligatorias:
///
///   Fase 0 — una fila insertada y no confirmada es invisible para las demás
///            sesiones (MVCC). Si la reserva viviera dentro de la transacción
///            de trabajo, dos reenvíos simultáneos de la misma operación no se
///            verían y ambos ejecutarían.
///   Fase 2 — tras un fallo la transacción de trabajo queda abortada y no
///            admite más sentencias; el cierre debe viajar por una conexión
///            sana.
/// </summary>
public sealed class ServicioIdempotencia(string cadena) : IServicioIdempotencia
{
    public async Task<ResultadoReserva> ReservarAsync(
        ContextoOperacion ctx, string hashPeticion, CancellationToken ct)
    {
        await using var conexion = new NpgsqlConnection(cadena);
        await conexion.OpenAsync(ct);

        var fila = await conexion.QuerySingleAsync<FilaReserva>(new CommandDefinition(
            "select veredicto, codigo_respuesta, cuerpo_respuesta::text as cuerpo_respuesta " +
            "  from wms.fn_reservar_operacion(@Id, @Alcance, @Ruta, @Hash, @Usuario)",
            new
            {
                Id = ctx.IdOperacionCompleto,
                ctx.Alcance,
                ctx.Ruta,
                Hash = hashPeticion,
                Usuario = ctx.UsuarioId
            }, cancellationToken: ct));

        var veredicto = fila.veredicto switch
        {
            "NUEVA"              => VeredictoReserva.Nueva,
            "EN_CURSO"           => VeredictoReserva.EnCurso,
            "YA_COMPLETADA"      => VeredictoReserva.YaCompletada,
            "CARGA_DISTINTA"     => VeredictoReserva.CargaDistinta,
            "CONFLICTO_DE_ACTOR" => VeredictoReserva.ConflictoDeActor,
            _ => throw new InvalidOperationException($"Veredicto desconocido: {fila.veredicto}")
        };

        return new ResultadoReserva(veredicto, fila.codigo_respuesta, fila.cuerpo_respuesta);
    }

    public Task SellarAsync(DbConnection conexion, DbTransaction tx, string idOperacion,
        int codigo, string cuerpoJson, CancellationToken ct) =>
        conexion.ExecuteAsync(new CommandDefinition(
            "select wms.fn_sellar_operacion(@Id, @Codigo, @Cuerpo::jsonb)",
            new { Id = idOperacion, Codigo = codigo, Cuerpo = cuerpoJson },
            transaction: tx, cancellationToken: ct));

    public async Task CerrarFallidaAsync(string idOperacion, int codigo, string detalle)
    {
        // Sin CancellationToken a propósito: este cierre debe completarse
        // aunque el cliente ya se haya ido, o el id quedaría bloqueado como
        // EN_PROCESO hasta que lo recoja el barrido.
        await using var conexion = new NpgsqlConnection(cadena);
        await conexion.OpenAsync(CancellationToken.None);
        await conexion.ExecuteAsync(
            "select wms.fn_cerrar_operacion_fallida(@Id, @Codigo, @Detalle)",
            new { Id = idOperacion, Codigo = codigo, Detalle = detalle });
    }

    private sealed record FilaReserva(string veredicto, int? codigo_respuesta, string? cuerpo_respuesta);
}
