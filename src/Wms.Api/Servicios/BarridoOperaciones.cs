using Dapper;
using Npgsql;

namespace Wms.Api.Servicios;

/// <summary>
/// Barrido de operaciones colgadas.
///
/// La migración 0003 programa `wms.fn_barrer_operaciones_colgadas()` con
/// pg_cron cuando la extensión está disponible, y cuando NO lo está deja un
/// aviso pidiendo programarlo «externamente». La imagen `postgres:16-alpine`
/// que usan Docker Compose y las verificaciones no la trae, así que ese
/// externamente era nadie: una operación que quedara `EN_PROCESO` seguía
/// bloqueando su `id_operacion` indefinidamente, y todo reintento recibía
/// WM013 para siempre.
///
/// Este servicio es ese «externamente». Es una red de último recurso, no el
/// mecanismo principal: el camino normal es que la propia petición cierre su
/// operación como FALLIDO en la fase 2. El barrido solo alcanza lo que ya no
/// tiene a nadie que lo cierre —el proceso murió entre la reserva y el
/// trabajo—, y la función tiene sus propias guardias para no declarar «no
/// aplicado» algo que sí dejó rastro en la bitácora.
///
/// Si pg_cron sí estuviera disponible, ejecutarlo por las dos vías es
/// inofensivo: la función es idempotente y solo toca filas que cumplen el
/// umbral de antigüedad.
/// </summary>
public sealed class BarridoOperaciones(
    string cadena, ILogger<BarridoOperaciones> log) : BackgroundService
{
    private static readonly TimeSpan Cadencia = TimeSpan.FromMinutes(1);

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // Un primer respiro para no competir con las migraciones ni con el
        // arranque de la API.
        try { await Task.Delay(Cadencia, ct); } catch (OperationCanceledException) { return; }

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await using var conexion = new NpgsqlConnection(cadena);
                await conexion.OpenAsync(ct);
                var barridas = await conexion.ExecuteScalarAsync<int>(
                    new CommandDefinition("select wms.fn_barrer_operaciones_colgadas()",
                        cancellationToken: ct));

                if (barridas > 0)
                    log.LogWarning("Barrido: {N} operación(es) abandonada(s) cerrada(s) como FALLIDO. " +
                                   "Su id vuelve a ser reejecutable.", barridas);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                // Que el barrido falle no puede tumbar la API: es una red de
                // seguridad, no una dependencia del camino normal.
                log.LogError(ex, "El barrido de operaciones colgadas falló; se reintenta en la siguiente vuelta.");
            }

            try { await Task.Delay(Cadencia, ct); } catch (OperationCanceledException) { return; }
        }
    }
}
