using System.Data;
using System.Data.Common;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using MediatR;
using Microsoft.Extensions.Logging;
using Wms.Application.Abstracciones;
using Wms.Application.Comun.Operaciones;

namespace Wms.Application.Importacion;

public sealed record ComandoImportar(string NombreArchivo, byte[] Contenido, string Modo)
    : IRequest<ResultadoImportacion>;

public sealed record ResultadoImportacion(
    long LoteId, string IdOperacion, string Estatus, string Modo,
    int RenglonesTotal, int RenglonesOk, int RenglonesError, int RenglonesOmitidos,
    bool FueReanudacion, IReadOnlyList<DetalleRenglon> Detalle);

public sealed record DetalleRenglon(
    int Numero, string Estatus, string? Accion, string? CodigoError, string? Mensaje,
    string? Sku, int? CantidadAplicada);

/// <summary>
/// La importación es la ÚNICA operación cuyo trabajo se confirma por partes:
/// procesar 3 000 renglones en una sola transacción retendría locks demasiado
/// tiempo. Eso rompe la premisa del resto del sistema —"FALLIDO significa que
/// no se aplicó nada"— y por eso necesita reglas propias:
///
///   1. El id_operacion del lote se deriva del CONTENIDO del archivo, no del
///      instante en que se eligió. Si se acuñara al abrir el selector, quien
///      reintenta tras un corte reseleccionaría el archivo, acuñaría un id
///      nuevo, y las llaves por renglón frescas NO colisionarían con las ya
///      aplicadas: los 3 000 renglones se aplicarían otra vez.
///   2. El lote es único por operación: el reintento LEE la fila existente y
///      REANUDA desde el primer renglón que no esté OK.
///   3. Cada renglón corre bajo su propio SAVEPOINT. Un 23505 sobre
///      ux_...__operacion significa "este renglón ya se aplicó": se marca
///      OMITIDO y se sigue. Sin el savepoint ese error mataría el chunk entero
///      y la reimportación no avanzaría nunca.
/// </summary>
public sealed class ManejadorImportar(
    IFabricaConexion fabrica, ContextoOperacion contexto, ILogger<ManejadorImportar> log)
    : IRequestHandler<ComandoImportar, ResultadoImportacion>
{
    private const int TamanoChunk = 500;

    public async Task<ResultadoImportacion> Handle(ComandoImportar cmd, CancellationToken ct)
    {
        var modo = cmd.Modo.ToUpperInvariant() is "ALTA_O_ACTUALIZA" ? "ALTA_O_ACTUALIZA" : "SOLO_ALTA";
        var hash = Convert.ToHexString(SHA256.HashData(cmd.Contenido)).ToLowerInvariant()[..16];
        var idLote = $"{contexto.UsuarioId}:imp-{hash}-{modo}";

        // ---------- PRIMERA PASADA: validar en memoria ----------
        var analisis = AnalizadorArchivo.Analizar(Encoding.UTF8.GetString(cmd.Contenido));

        await using var conexion = await fabrica.AbrirAsync(ct);

        // ---------- Lote: alta o reanudación ----------
        var (loteId, fueReanudacion) = await AbrirLoteAsync(conexion, idLote, cmd.NombreArchivo, modo, ct);

        var yaOk = (await conexion.QueryAsync<int>(
            "select numero_renglon from wms.tbl_renglones_importacion " +
            " where lote_id = @LoteId and estatus = 'OK'", new { LoteId = loteId })).ToHashSet();

        if (fueReanudacion && yaOk.Count > 0)
            log.LogInformation("Reanudando lote {Lote}: {N} renglones ya aplicados se omiten.",
                idLote, yaOk.Count);

        var detalle = new List<DetalleRenglon>();

        // Los inválidos se registran sin tocar inventario.
        foreach (var inv in analisis.Invalidos)
        {
            await RegistrarRenglonAsync(conexion, null, loteId, inv.Numero, inv.CargaOriginalJson,
                "ERROR", null, inv.Codigo, inv.Mensaje, null, null, null, ct);
            detalle.Add(new DetalleRenglon(inv.Numero, "ERROR", null, inv.Codigo, inv.Mensaje, null, null));
        }

        // Un archivo sin un solo renglón válido nunca abre transacción de trabajo.
        if (analisis.Validos.Count == 0)
        {
            await CerrarLoteAsync(conexion, loteId, analisis.TotalRenglones, ct);
            return await ComponerAsync(conexion, loteId, idLote, modo, fueReanudacion, detalle, ct);
        }

        // ---------- SEGUNDA PASADA: aplicar por chunks ----------
        foreach (var chunk in analisis.Validos.Chunk(TamanoChunk))
        {
            var tx = await conexion.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
            try
            {
                // El contexto de operador se fija al abrir CADA chunk: los GUC
                // son locales a la transacción, y el trigger que restringe el
                // alta en catálogos lo lee al crear un producto nuevo —antes de
                // que fn_ajustar_existencia haya fijado nada—.
                await conexion.ExecuteAsync(new CommandDefinition(
                    "select set_config('wms.ctx_usuario_id', @Usuario, true)",
                    new { Usuario = contexto.UsuarioId.ToString() },
                    transaction: tx, cancellationToken: ct));

                foreach (var r in chunk)
                {
                    if (yaOk.Contains(r.Numero))
                    {
                        detalle.Add(new DetalleRenglon(r.Numero, "OMITIDO", "SIN_CAMBIO",
                            CodigoErrorImportacion.YaAplicado, "El renglón ya se aplicó en un intento previo.",
                            null, null));
                        continue;
                    }
                    detalle.Add(await AplicarRenglonAsync(conexion, tx, loteId, idLote, modo, r, ct));
                }
                await tx.CommitAsync(CancellationToken.None);
            }
            catch (Exception ex)
            {
                try { await tx.RollbackAsync(CancellationToken.None); } catch { /* conexión rota */ }
                log.LogError(ex, "El chunk falló entero; los chunks previos siguen confirmados.");
                throw;
            }
            finally { await tx.DisposeAsync(); }
        }

        await CerrarLoteAsync(conexion, loteId, analisis.TotalRenglones, ct);
        return await ComponerAsync(conexion, loteId, idLote, modo, fueReanudacion, detalle, ct);
    }

    // -----------------------------------------------------------------
    private async Task<(long LoteId, bool FueReanudacion)> AbrirLoteAsync(
        DbConnection c, string idLote, string archivo, string modo, CancellationToken ct)
    {
        var insertado = await c.QuerySingleOrDefaultAsync<long?>(new CommandDefinition(
            "insert into wms.tbl_lotes_importacion " +
            "  (nombre_archivo, tipo_lote, modo, id_operacion, creado_por_usuario_id) " +
            "values (@Archivo, 'COMBINADO', @Modo, @Id, @Usuario) " +
            "on conflict (id_operacion) do nothing returning id",
            new { Archivo = archivo, Modo = modo, Id = idLote, Usuario = contexto.UsuarioId },
            cancellationToken: ct));

        if (insertado is not null) return (insertado.Value, false);

        // Ya existía: se REANUDA el lote, no se crea otro con llaves frescas.
        var existente = await c.QuerySingleAsync<long>(new CommandDefinition(
            "update wms.tbl_lotes_importacion set estatus = 'PROCESANDO', finalizado_en = null " +
            " where id_operacion = @Id returning id", new { Id = idLote }, cancellationToken: ct));
        return (existente, true);
    }

    private async Task<DetalleRenglon> AplicarRenglonAsync(
        DbConnection c, DbTransaction tx, long loteId, string idLote, string modo,
        RenglonImportacion r, CancellationToken ct)
    {
        var punto = $"sp_{r.Numero}";
        await c.ExecuteAsync(new CommandDefinition($"savepoint {punto}", transaction: tx, cancellationToken: ct));
        try
        {
            var categoriaId = await c.QuerySingleOrDefaultAsync<long?>(new CommandDefinition(
                "select id from wms.cat_categorias where codigo = @C",
                new { C = r.CategoriaCodigo }, transaction: tx, cancellationToken: ct));
            if (categoriaId is null)
                return await FallarAsync(c, tx, punto, loteId, r, CodigoErrorImportacion.CategoriaInexistente,
                    $"No existe la categoría '{r.CategoriaCodigo}'.", ct);

            var almacenId = await c.QuerySingleOrDefaultAsync<long?>(new CommandDefinition(
                "select id from wms.cat_almacenes where codigo = @A",
                new { A = r.AlmacenCodigo }, transaction: tx, cancellationToken: ct));
            if (almacenId is null)
                return await FallarAsync(c, tx, punto, loteId, r, CodigoErrorImportacion.AlmacenInexistente,
                    $"No existe el almacén '{r.AlmacenCodigo}'.", ct);

            // Identidad del producto en la importación: categoría + nombre.
            var existente = await c.QuerySingleOrDefaultAsync<(long Id, string Sku)?>(new CommandDefinition(
                "select id, sku from wms.cat_productos " +
                " where categoria_id = @Cat and lower(btrim(nombre)) = lower(btrim(@Nom))",
                new { Cat = categoriaId, Nom = r.NombreProducto }, transaction: tx, cancellationToken: ct));

            long productoId; string sku; string accion;

            if (existente is null)
            {
                var nuevo = await c.QuerySingleAsync<(long Id, string Sku)>(new CommandDefinition(
                    "insert into wms.cat_productos (categoria_id, nombre, descripcion, precio_unitario, estatus) " +
                    "values (@Cat, @Nom, @Desc, @Precio, @Estatus) returning id, sku",
                    new { Cat = categoriaId, Nom = r.NombreProducto, Desc = r.Descripcion,
                          Precio = r.PrecioUnitario, Estatus = r.Estatus },
                    transaction: tx, cancellationToken: ct));
                (productoId, sku, accion) = (nuevo.Id, nuevo.Sku, "ALTA");
            }
            else if (modo == "SOLO_ALTA")
            {
                await RegistrarRenglonAsync(c, tx, loteId, r.Numero, r.CargaOriginalJson,
                    "OMITIDO", "OMISION", CodigoErrorImportacion.SkuYaExiste,
                    $"'{r.NombreProducto}' ya existe como {existente.Value.Sku}; el modo es SOLO_ALTA.",
                    existente.Value.Id, almacenId, null, ct);
                return new DetalleRenglon(r.Numero, "OMITIDO", "OMISION",
                    CodigoErrorImportacion.SkuYaExiste,
                    $"Ya existe como {existente.Value.Sku}.", existente.Value.Sku, null);
            }
            else
            {
                await c.ExecuteAsync(new CommandDefinition(
                    "update wms.cat_productos set descripcion = @Desc, precio_unitario = @Precio, " +
                    "       estatus = @Estatus where id = @Id",
                    new { Desc = r.Descripcion, Precio = r.PrecioUnitario, Estatus = r.Estatus,
                          Id = existente.Value.Id }, transaction: tx, cancellationToken: ct));
                (productoId, sku, accion) = (existente.Value.Id, existente.Value.Sku, "ACTUALIZACION");
            }

            long? movimientoId = null;
            if (r.CantidadInicial > 0)
            {
                // Llave DERIVADA por renglón: dos renglones del mismo archivo
                // pueden tocar legítimamente el mismo par producto/almacén.
                await c.ExecuteAsync(new CommandDefinition(
                    "select wms.fn_ajustar_existencia(@Prod, @Alm, @Cant, 'IMPORTACION', @Usuario, " +
                    "       @IdOp, 'IMPORTACION', null, @Lote, 'Carga masiva', null)",
                    new { Prod = productoId, Alm = almacenId, Cant = r.CantidadInicial,
                          Usuario = contexto.UsuarioId, IdOp = $"{idLote}:{r.Numero}", Lote = loteId },
                    transaction: tx, cancellationToken: ct));

                movimientoId = await c.QuerySingleOrDefaultAsync<long?>(new CommandDefinition(
                    "select id from wms.tbl_movimientos_inventario where id_operacion = @IdOp",
                    new { IdOp = $"{idLote}:{r.Numero}" }, transaction: tx, cancellationToken: ct));
            }

            if (r.CantidadMinima > 0)
                await c.ExecuteAsync(new CommandDefinition(
                    "update wms.tbl_inventario set cantidad_minima = @Min " +
                    " where producto_id = @Prod and almacen_id = @Alm",
                    new { Min = r.CantidadMinima, Prod = productoId, Alm = almacenId },
                    transaction: tx, cancellationToken: ct));

            await RegistrarRenglonAsync(c, tx, loteId, r.Numero, r.CargaOriginalJson,
                "OK", accion, null, null, productoId, almacenId, r.CantidadInicial, ct, movimientoId);

            return new DetalleRenglon(r.Numero, "OK", accion, null, null, sku, r.CantidadInicial);
        }
        catch (DbException ex) when (ex.SqlState == "23505")
        {
            // Se retrocede SOLO este renglon; el chunk continua. Sin el
            // savepoint, este error mataria los 500 renglones del chunk y la
            // reimportacion no avanzaria nunca.
            await c.ExecuteAsync(new CommandDefinition($"rollback to savepoint {punto}",
                transaction: tx, cancellationToken: ct));

            // ¿Fue el indice de idempotencia? Se comprueba por SEMANTICA —si ya
            // existe el movimiento de esta llave, el renglon ya se aplico— en
            // vez de comparar el nombre del constraint contra una cadena, que
            // ademas acoplaria esta capa al driver.
            var yaAplicado = await c.QuerySingleOrDefaultAsync<long?>(new CommandDefinition(
                "select id from wms.tbl_movimientos_inventario where id_operacion = @IdOp",
                new { IdOp = $"{idLote}:{r.Numero}" }, transaction: tx, cancellationToken: ct));

            var (codigo, mensaje, estatus, accion) = yaAplicado is not null
                ? (CodigoErrorImportacion.YaAplicado, "El renglon ya se habia aplicado; se omite.", "OMITIDO", "SIN_CAMBIO")
                : (CodigoErrorImportacion.FallaAlAplicar, ex.Message, "ERROR", (string?)null);

            await RegistrarRenglonAsync(c, tx, loteId, r.Numero, r.CargaOriginalJson,
                estatus, accion, codigo, mensaje, null, null, null, ct);
            return new DetalleRenglon(r.Numero, estatus, accion, codigo, mensaje, null, null);
        }
        catch (DbException ex) when (ex.SqlState is "WM020" or "WM014")
        {
            // El renglon exigia dar de alta un producto y el operador no es
            // SISTEMA. Se marca solo ESTE renglon: los que unicamente
            // actualizan inventario de productos existentes siguen aplicandose.
            return await FallarAsync(c, tx, punto, loteId, r,
                CodigoErrorImportacion.PermisoAltaCatalogo,
                "Este renglon requiere dar de alta un producto nuevo, y eso esta " +
                "reservado al operador SISTEMA.", ct);
        }
        catch (DbException ex)
        {
            return await FallarAsync(c, tx, punto, loteId, r, CodigoErrorImportacion.FallaAlAplicar,
                ex.Message, ct);
        }
    }

    private async Task<DetalleRenglon> FallarAsync(
        DbConnection c, DbTransaction tx, string punto, long loteId, RenglonImportacion r,
        string codigo, string mensaje, CancellationToken ct,
        string estatus = "ERROR", string? accion = null)
    {
        await c.ExecuteAsync(new CommandDefinition($"rollback to savepoint {punto}",
            transaction: tx, cancellationToken: ct));
        await RegistrarRenglonAsync(c, tx, loteId, r.Numero, r.CargaOriginalJson,
            estatus, accion, codigo, mensaje, null, null, null, ct);
        return new DetalleRenglon(r.Numero, estatus, accion, codigo, mensaje, null, null);
    }

    private static Task RegistrarRenglonAsync(
        DbConnection c, DbTransaction? tx, long loteId, int numero, string carga,
        string estatus, string? accion, string? codigo, string? mensaje,
        long? productoId, long? almacenId, int? cantidad, CancellationToken ct,
        long? movimientoId = null) =>
        c.ExecuteAsync(new CommandDefinition(
            "insert into wms.tbl_renglones_importacion " +
            "  (lote_id, numero_renglon, carga_original, estatus, accion, codigo_error, " +
            "   mensaje_error, producto_id, almacen_id, cantidad_aplicada, movimiento_id) " +
            "values (@Lote, @Num, @Carga::jsonb, @Estatus, @Accion, @Codigo, @Mensaje, " +
            "        @Prod, @Alm, @Cant, @Mov) " +
            "on conflict (lote_id, numero_renglon) do update set " +
            "  estatus = excluded.estatus, accion = excluded.accion, " +
            "  codigo_error = excluded.codigo_error, mensaje_error = excluded.mensaje_error, " +
            "  producto_id = excluded.producto_id, almacen_id = excluded.almacen_id, " +
            "  cantidad_aplicada = excluded.cantidad_aplicada, movimiento_id = excluded.movimiento_id",
            new { Lote = loteId, Num = numero, Carga = carga, Estatus = estatus, Accion = accion,
                  Codigo = codigo, Mensaje = mensaje, Prod = productoId, Alm = almacenId,
                  Cant = cantidad, Mov = movimientoId },
            transaction: tx, cancellationToken: ct));

    private static Task CerrarLoteAsync(DbConnection c, long loteId, int total, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            "update wms.tbl_lotes_importacion l set " +
            "  renglones_total = @Total, " +
            "  renglones_ok    = (select count(*) from wms.tbl_renglones_importacion r " +
            "                      where r.lote_id = l.id and r.estatus = 'OK'), " +
            "  renglones_error = (select count(*) from wms.tbl_renglones_importacion r " +
            "                      where r.lote_id = l.id and r.estatus = 'ERROR'), " +
            "  finalizado_en = now(), " +
            "  estatus = case " +
            "     when (select count(*) from wms.tbl_renglones_importacion r " +
            "            where r.lote_id = l.id and r.estatus = 'OK') = 0 then 'FALLIDO' " +
            "     when exists (select 1 from wms.tbl_renglones_importacion r " +
            "                   where r.lote_id = l.id and r.estatus = 'ERROR') " +
            "          then 'COMPLETADO_CON_ERRORES' " +
            "     else 'COMPLETADO' end " +
            " where l.id = @Lote",
            new { Total = total, Lote = loteId }, cancellationToken: ct));

    private static async Task<ResultadoImportacion> ComponerAsync(
        DbConnection c, long loteId, string idLote, string modo, bool reanudacion,
        List<DetalleRenglon> detalle, CancellationToken ct)
    {
        var lote = await c.QuerySingleAsync<(string estatus, int renglones_total, int renglones_ok, int renglones_error)>(
            new CommandDefinition(
                "select estatus, renglones_total, renglones_ok, renglones_error " +
                "  from wms.tbl_lotes_importacion where id = @Id",
                new { Id = loteId }, cancellationToken: ct));

        return new ResultadoImportacion(loteId, idLote, lote.estatus, modo,
            lote.renglones_total, lote.renglones_ok, lote.renglones_error,
            detalle.Count(d => d.Estatus == "OMITIDO"),
            reanudacion, detalle.OrderBy(d => d.Numero).ToList());
    }
}
