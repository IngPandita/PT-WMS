using System.Data.Common;
using Wms.Application.Comun.Operaciones;
using Wms.Application.Comun.Sku;

namespace Wms.Application.Abstracciones;

public interface IFabricaConexion
{
    /// <summary>Conexión abierta y lista. El llamador la libera.</summary>
    Task<DbConnection> AbrirAsync(CancellationToken ct);
}

public enum VeredictoReserva { Nueva, EnCurso, YaCompletada, CargaDistinta, ConflictoDeActor }

public sealed record ResultadoReserva(VeredictoReserva Veredicto, int? CodigoRespuesta, string? CuerpoRespuesta);

/// <summary>
/// Sobre de idempotencia. Las fases 0 y 2 usan conexión PROPIA con commit
/// inmediato: una fila no confirmada es invisible por MVCC, así que dos
/// reenvíos simultáneos no se verían el uno al otro. La fase 2 además no
/// puede viajar por la conexión de trabajo, que tras un fallo queda abortada.
/// </summary>
public interface IServicioIdempotencia
{
    Task<ResultadoReserva> ReservarAsync(ContextoOperacion ctx, string hashPeticion, CancellationToken ct);

    /// <summary>Sella DENTRO de la transacción de trabajo: movimiento y sello confirman o fracasan juntos.</summary>
    Task SellarAsync(DbConnection conexion, DbTransaction tx, string idOperacion, int codigo, string cuerpoJson, CancellationToken ct);

    /// <summary>Deja la operación REEJECUTABLE con el mismo id: no aplicó nada.</summary>
    Task CerrarFallidaAsync(string idOperacion, int codigo, string detalle);
}

public interface IRepositorioReglasSku
{
    Task<AnalizadorSku> ObtenerAnalizadorAsync(CancellationToken ct);
}
