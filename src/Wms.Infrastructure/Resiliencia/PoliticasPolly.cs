using Microsoft.Extensions.Logging;
using Npgsql;
using Polly;
using Polly.Retry;
using Wms.Domain.Errores;

namespace Wms.Infrastructure.Resiliencia;

/// <summary>
/// Reintentos acotados a los SQLSTATE genuinamente transitorios del motor:
/// 40001, 40P01 y 55P03. Nunca se reintenta la clase WM ni 23505: son
/// deterministas y reintentarlos solo quema presupuesto.
///
/// El reintento usa el MISMO id_operacion. Es seguro por construccion: el
/// intento fallido dejo la operacion en FALLIDO y fn_reservar_operacion la
/// readmite como NUEVA. Acunar un id nuevo aqui seria justo el error que
/// produce la doble aplicacion.
/// </summary>
public static class PoliticasPolly
{
    public static ResiliencePipeline Construir(ILogger log) =>
        new ResiliencePipelineBuilder()
            .AddRetry(new RetryStrategyOptions
            {
                ShouldHandle = new PredicateBuilder().Handle<PostgresException>(
                    ex => CodigoWms.EsTransitorio(ex.SqlState)),
                MaxRetryAttempts = 3,
                Delay = TimeSpan.FromMilliseconds(50),
                BackoffType = DelayBackoffType.Exponential,
                UseJitter = true,
                OnRetry = args =>
                {
                    var sqlState = (args.Outcome.Exception as PostgresException)?.SqlState;
                    log.LogWarning("Reintento {N} por SQLSTATE {Estado}; se conserva el id_operacion.",
                        args.AttemptNumber + 1, sqlState);
                    return default;
                }
            })
            .AddTimeout(TimeSpan.FromSeconds(10))
            .Build();
}
