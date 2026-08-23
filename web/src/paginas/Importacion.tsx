import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Download, Upload } from 'lucide-react'
import { Encabezado } from '../App'
import { ErrorApi, peticion } from '../lib/api'
import type { ResultadoImportacion } from '../lib/tipos'
import { usarSesion } from '../hooks/usarSesion'
import { EstadoVacio, Insignia, tonoEstatus, usarAvisos } from '../componentes/Base'

export function PaginaImportacion() {
  const { usuario } = usarSesion()
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()
  const [archivo, setArchivo] = useState<File | null>(null)
  const [modo, setModo] = useState('SOLO_ALTA')
  const [resultado, setResultado] = useState<ResultadoImportacion | null>(null)

  const importar = useMutation({
    mutationFn: () => {
      const fd = new FormData()
      fd.append('archivo', archivo!)
      fd.append('modo', modo)
      // La importación NO manda X-Operation-Id: su identidad se deriva del
      // CONTENIDO del archivo. Si el cliente acuñara un id nuevo al reintentar,
      // las llaves por renglón tampoco colisionarían y todo se aplicaría dos veces.
      return peticion<ResultadoImportacion>('/api/importacion', {
        metodo: 'POST', formulario: fd, usuarioId: usuario!.id,
      })
    },
    onSuccess: (r) => {
      setResultado(r)
      avisar({
        tono: r.renglonesError > 0 ? 'error' : 'exito',
        texto: `${r.renglonesOk} aplicados · ${r.renglonesError} con error · ${r.renglonesOmitidos} omitidos`,
        detalle: r.fueReanudacion
          ? 'Se reanudó un lote previo: los renglones ya aplicados no se repitieron.'
          : undefined,
      })
      clienteQuery.invalidateQueries({ queryKey: ['inventario'] })
      clienteQuery.invalidateQueries({ queryKey: ['indicadores'] })
    },
    onError: (e: ErrorApi) => avisar({ tono: 'error', texto: e.titulo, detalle: e.detalle ?? undefined }),
  })

  return (
    <>
      <Encabezado
        titulo="Importación" descripcion="Carga masiva de productos e inventario."
        acciones={
          <a className="boton-secundario" href="/api/importacion/plantilla" download>
            <Download className="h-3.5 w-3.5" /> Descargar plantilla
          </a>
        }
      />

      <div className="grid gap-4 p-6 lg:grid-cols-3">
        <section className="tarjeta space-y-3 p-4">
          <div>
            <label className="etiqueta mb-1 block">Archivo CSV</label>
            <input type="file" accept=".csv,text/csv" className="campo text-2xs"
                   onChange={(e) => { setArchivo(e.target.files?.[0] ?? null); setResultado(null) }} />
          </div>

          <div>
            <label className="etiqueta mb-1 block">Al encontrar un producto existente</label>
            <select className="campo" value={modo} onChange={(e) => setModo(e.target.value)}>
              <option value="SOLO_ALTA">Omitirlo (solo alta)</option>
              <option value="ALTA_O_ACTUALIZA">Actualizarlo y sumar la cantidad</option>
            </select>
          </div>

          <button className="boton-primario w-full" disabled={!archivo || !usuario || importar.isPending}
                  onClick={() => importar.mutate()}>
            <Upload className="h-3.5 w-3.5" /> {importar.isPending ? 'Procesando…' : 'Importar'}
          </button>

          <p className="text-2xs leading-relaxed text-tinta-500">
            El SKU no va en la plantilla: lo acuña el servidor. Reimportar el mismo archivo
            es seguro — se reanuda el lote y los renglones ya aplicados se omiten en vez de
            volver a sumar.
          </p>
        </section>

        <section className="tarjeta overflow-hidden lg:col-span-2">
          {!resultado ? (
            <EstadoVacio
              titulo="Sin importaciones en esta sesión"
              descripcion="Descargue la plantilla, capture los renglones y súbala. Verá el resultado renglón por renglón."
            />
          ) : (
            <>
              <div className="flex items-center justify-between border-b border-tinta-200 px-4 py-3">
                <div>
                  <div className="flex items-center gap-2">
                    <h2 className="text-sm font-medium text-tinta-800">Lote #{resultado.loteId}</h2>
                    <Insignia tono={tonoEstatus[resultado.estatus]}>{resultado.estatus.toLowerCase()}</Insignia>
                    {resultado.fueReanudacion && <Insignia tono="info">reanudado</Insignia>}
                  </div>
                  <p className="mt-0.5 font-mono text-2xs text-tinta-500">{resultado.idOperacion}</p>
                </div>
                <div className="flex gap-4 text-right">
                  {[['Aplicados', resultado.renglonesOk], ['Con error', resultado.renglonesError],
                    ['Omitidos', resultado.renglonesOmitidos]].map(([e, v]) => (
                    <div key={String(e)}>
                      <p className="etiqueta">{e}</p>
                      <p className="text-base font-semibold tabular-nums">{v}</p>
                    </div>
                  ))}
                </div>
              </div>

              <div className="max-h-[28rem] overflow-y-auto">
                <table className="w-full text-sm">
                  <thead className="sticky top-0 bg-tinta-50/95 backdrop-blur">
                    <tr className="[&>th]:px-4 [&>th]:py-2 [&>th]:text-left [&>th]:font-medium [&>th]:text-tinta-600">
                      <th className="w-16">Renglón</th><th>Estatus</th><th>SKU</th><th>Detalle</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-tinta-100">
                    {resultado.detalle.map((d) => (
                      <tr key={d.numero}>
                        <td className="px-4 py-2 tabular-nums text-tinta-500">{d.numero}</td>
                        <td className="px-4 py-2">
                          <Insignia tono={tonoEstatus[d.estatus]}>{d.estatus.toLowerCase()}</Insignia>
                          {d.accion && <span className="ml-1 text-2xs text-tinta-500">{d.accion.toLowerCase()}</span>}
                        </td>
                        <td className="px-4 py-2 font-mono text-2xs text-tinta-600">{d.sku ?? '—'}</td>
                        <td className="px-4 py-2 text-2xs text-tinta-600">
                          {d.codigoError && (
                            <span className="mr-1 rounded bg-tinta-100 px-1 py-0.5 font-mono text-tinta-700">
                              {d.codigoError}
                            </span>
                          )}
                          {d.mensaje ?? (d.cantidadAplicada != null ? `+${d.cantidadAplicada} unidades` : '')}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </section>
      </div>
    </>
  )
}
