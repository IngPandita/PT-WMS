using System.Data;
using System.Data.Common;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Wms.Application.Abstracciones;
using Wms.Domain.Errores;

namespace Wms.Application.Comun.Operaciones;

/// <summary>Valor de la operación más si vino de un reenvío ya aplicado.</summary>
public sealed record ResultadoIdempotente<T>(T Valor, bool FueReenvio);

/// <summary>
/// Las tres fases del protocolo, en un solo lugar.
///
///   Fase 0 · reserva   — conexión propia, COMMIT inmediato. Una fila no
///                        confirmada es invisible por MVCC: si viviera dentro
///                        de la transacción de trabajo, dos reenvíos
///                        simultáneos no se verían y ambos ejecutarían.
///   Fase 1 · trabajo   — mutación y sellado en la MISMA transacción, para que
///                        confirmen o fracasen juntos.
///   Fase 2 · cierre    — conexión propia: tras un fallo la de trabajo queda
///                        abortada. Marca FALLIDO, que deja el id reejecutable.
///
/// Repetir esto en cada manejador invitaba a que uno se saltara un paso; el
/// paso que se olvida siempre es el que rompe la garantía.
/// </summary>
public sealed class EjecutorIdempotente(
    IFabricaConexion fabrica,
    IServicioIdempotencia idempotencia,
    ILogger<EjecutorIdempotente> log)
{
    public async Task<ResultadoIdempotente<T>> EjecutarAsync<T>(
        ContextoOperacion ctx,
        string claveRuta,
        IReadOnlyDictionary<string, object?> camposIntencion,
        Func<DbConnection, DbTransaction, CancellationToken, Task<T>> trabajo,
        CancellationToken ct)
    {
        var huella = HuellaPeticion.Calcular(claveRuta, camposIntencion);

        // ---------- FASE 0 ----------
        var reserva = await idempotencia.ReservarAsync(ctx, huella, ct);
        switch (reserva.Veredicto)
        {
            case VeredictoReserva.YaCompletada:
                log.LogInformation("Reenvio de {Op}: se devuelve la respuesta original sin reaplicar.",
                    ctx.IdOperacionCompleto);
                return new ResultadoIdempotente<T>(
                    JsonSerializer.Deserialize<T>(reserva.CuerpoRespuesta!)!, FueReenvio: true);

            case VeredictoReserva.EnCurso:
                throw new ExcepcionWms("WM013", 409,
                    "Otro envio de esta misma operacion se esta procesando en este momento.",
                    "Reintente en un momento con el MISMO X-Operation-Id.");

            case VeredictoReserva.CargaDistinta:
                throw new ExcepcionWms("WM015", 409,
                    "Esta operacion ya se registro con una carga, alcance o ruta distintos.",
                    "No acune un id nuevo: consulte /api/inventario/movimientos?idOperacion=" +
                    ctx.IdOperacionCompleto + " para saber si la intencion ya se materializo.");

            case VeredictoReserva.ConflictoDeActor:
                throw new ExcepcionWms("WM016", 409,
                    "El identificador de operacion pertenece a otro operador.");
        }

        // ---------- FASE 1 ----------
        // Abrir la conexion e iniciar la transaccion entran DENTRO del try a
        // proposito. Para cuando se llega aqui la operacion ya quedo reservada
        // como EN_PROCESO, y esas dos llamadas tambien pueden fallar —el token
        // ya viene cancelado si el cliente corto—. Con la apertura fuera del
        // try, ese fallo se propagaba sin cerrar la reserva y el id quedaba
        // bloqueado: todo reintento recibia WM013 hasta que pasara el barrido,
        // que es exactamente lo contrario de lo que el protocolo promete.
        DbConnection? conexion = null;
        DbTransaction? tx = null;
        try
        {
            conexion = await fabrica.AbrirAsync(ct);
            tx = await conexion.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);

            var valor = await trabajo(conexion, tx, ct);

            await idempotencia.SellarAsync(conexion, tx, ctx.IdOperacionCompleto,
                200, JsonSerializer.Serialize(valor), ct);

            // El COMMIT nunca se cancela: abortarlo dejaria la conexion en
            // estado indefinido, que es justo el problema que se evita.
            await tx.CommitAsync(CancellationToken.None);
            return new ResultadoIdempotente<T>(valor, FueReenvio: false);
        }
        catch (Exception ex)
        {
            if (tx is not null)
            {
                try { await tx.RollbackAsync(CancellationToken.None); }
                catch (Exception exRollback)
                {
                    // Sobre una conexion rota el rollback vuelve a lanzar y
                    // suplantaria la excepcion original. El servidor ya aborto la
                    // transaccion por su cuenta.
                    log.LogWarning(exRollback, "Rollback fallido; la conexion se descarta.");
                }
            }

            // ---------- FASE 2 ----------
            await idempotencia.CerrarFallidaAsync(ctx.IdOperacionCompleto, 500, ex.Message);
            throw;
        }
        finally
        {
            if (tx is not null) await tx.DisposeAsync();
            if (conexion is not null) await conexion.DisposeAsync();
        }
    }
}
