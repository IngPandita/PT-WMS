import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Download, Search, SlidersHorizontal } from 'lucide-react'
import { Encabezado } from '../App'
import { ErrorApi, peticion } from '../lib/api'
import type { Almacen, FilaTablero } from '../lib/tipos'
import { usarSesion } from '../hooks/usarSesion'
import { AjusteRapido } from '../componentes/AjusteRapido'
import { ModalAjuste } from '../componentes/ModalAjuste'
import { EstadoVacio, Insignia, TablaSkeleton, tonoEstatus, usarAvisos } from '../componentes/Base'
import { POR_PAGINA, Paginador, usarPaginaConFiltros, type Paginado } from '../componentes/Paginador'

const ROLES_QUE_EXPORTAN = ['SUPERVISOR', 'SISTEMA']

export function PaginaInventario() {
  const { usuario } = usarSesion()
  const avisar = usarAvisos()
  const [texto, setTexto] = useState('')
  const [almacenId, setAlmacenId] = useState<number | ''>('')
  const [soloBajas, setSoloBajas] = useState(false)
  const [ajustando, setAjustando] = useState<FilaTablero | null>(null)
  const [exportando, setExportando] = useState(false)

  const { data: almacenes = [] } = useQuery({
    queryKey: ['catalogo', 'almacenes'],
    queryFn: async () => (await peticion<{elementos: Almacen[]}>('/api/catalogos/almacenes')).elementos,
  })

  // Los filtros SIN la pagina: al cambiar cualquiera de ellos hay que volver
  // a la 1, o el usuario veria una lista vacia sin explicacion.
  const filtros = new URLSearchParams()
  if (texto) filtros.set('q', texto)
  if (almacenId) filtros.set('almacenId', String(almacenId))
  if (soloBajas) filtros.set('soloExistenciaBaja', 'true')

  const [pagina, setPagina] = usarPaginaConFiltros(filtros.toString())

  const parametros = new URLSearchParams(filtros)
  parametros.set('pagina', String(pagina))
  parametros.set('porPagina', String(POR_PAGINA))

  const { data, isLoading } = useQuery({
    queryKey: ['inventario', filtros.toString(), pagina],
    queryFn: () => peticion<Paginado<FilaTablero>>(`/api/inventario?${parametros}`),
    placeholderData: (previo) => previo,   // evita el parpadeo al cambiar de pagina
  })
  const filas = data?.elementos

  const puedeExportar = usuario ? ROLES_QUE_EXPORTAN.includes(usuario.rol) : false

  /**
   * La exportación la genera el BACKEND y llega como flujo. El navegador solo
   * recibe el archivo; no se descargan los registros para armarlo aquí.
   *
   * Se usa fetch en vez de un <a download> porque hay que mandar el encabezado
   * de operador, y un enlace no puede llevar encabezados. Los mismos filtros
   * de la pantalla viajan en la URL, así que el archivo coincide con lo que se
   * está viendo.
   */
  const exportar = async () => {
    if (!usuario) return
    setExportando(true)
    try {
      // Se exportan los FILTROS, nunca la pagina: el archivo debe traer todo
      // el conjunto filtrado, no los 25 que se ven.
      const respuesta = await fetch(`/api/inventario/exportar?${filtros}`, {
        headers: { 'X-Usuario-Id': String(usuario.id) },
      })
      if (!respuesta.ok) {
        const cuerpo = await respuesta.json().catch(() => null)
        throw new ErrorApi(respuesta.status, cuerpo?.codigoWms ?? null,
          cuerpo?.title ?? 'No se pudo exportar', cuerpo?.detail ?? null)
      }
      const blob = await respuesta.blob()
      const url = URL.createObjectURL(blob)
      const enlace = document.createElement('a')
      enlace.href = url
      enlace.download = respuesta.headers.get('Content-Disposition')
        ?.match(/filename="([^"]+)"/)?.[1] ?? 'inventario.csv'
      enlace.click()
      URL.revokeObjectURL(url)
      avisar({
        tono: 'exito', texto: 'Exportación lista',
        detalle: 'El archivo respeta los filtros aplicados en pantalla.',
      })
    } catch (e) {
      const err = e as ErrorApi
      avisar({ tono: 'error', texto: err.titulo, detalle: err.detalle ?? undefined })
    } finally {
      setExportando(false)
    }
  }

  return (
    <>
      <Encabezado
        titulo="Inventario"
        descripcion="Existencias por producto y almacén. Los controles +/− aplican de inmediato."
        acciones={
          <button
            className="boton-secundario" onClick={exportar}
            disabled={!puedeExportar || exportando}
            title={puedeExportar
              ? 'Exporta a CSV respetando los filtros aplicados'
              : 'La exportación incluye precios y valuación: se limita a SUPERVISOR y SISTEMA'}
          >
            <Download className="h-3.5 w-3.5" />
            {exportando ? 'Exportando…' : 'Exportar'}
          </button>
        }
      />

      <div className="flex flex-wrap items-center gap-2 border-b border-tinta-200 bg-white px-6 py-3">
        <div className="relative">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-tinta-400" />
          <input
            className="campo w-64 pl-8" placeholder="Buscar por SKU o nombre…"
            value={texto} onChange={(e) => setTexto(e.target.value)}
          />
        </div>
        <select className="campo w-44" value={almacenId}
                onChange={(e) => setAlmacenId(e.target.value ? Number(e.target.value) : '')}>
          <option value="">Todos los almacenes</option>
          {almacenes.map((a) => <option key={a.id} value={a.id}>{a.codigo} · {a.nombre}</option>)}
        </select>
        <label className="flex items-center gap-1.5 text-sm text-tinta-600">
          <input type="checkbox" checked={soloBajas} onChange={(e) => setSoloBajas(e.target.checked)} />
          Solo existencia baja
        </label>
        {!puedeExportar && usuario && (
          <span className="ml-auto text-2xs text-tinta-400">
            {usuario.nombre} no tiene permiso de exportación
          </span>
        )}
      </div>

      <div className="p-6">
        <div className="tarjeta overflow-hidden">
          {isLoading ? (
            <TablaSkeleton columnas={7} />
          ) : !filas?.length ? (
            <EstadoVacio
              titulo="Sin resultados"
              descripcion="Ningún producto coincide con el filtro. Pruebe con otro texto o quite el filtro de existencia baja."
            />
          ) : (
            <table className="w-full text-sm">
              <thead className="border-b border-tinta-200 bg-tinta-50/60">
                <tr className="[&>th]:px-4 [&>th]:py-2 [&>th]:text-left [&>th]:font-medium [&>th]:text-tinta-600">
                  <th>SKU</th><th>Producto</th><th>Localizador</th>
                  <th className="!text-right">Reservado</th>
                  <th className="!text-right">Disponible</th>
                  <th className="!text-right">Existencia</th>
                  <th className="!text-right">Ajustar</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-tinta-100">
                {filas.map((f) => (
                  <tr key={`${f.productoId}-${f.almacenId}`} className="hover:bg-tinta-50/50">
                    <td className="px-4 py-2 font-mono text-2xs text-tinta-600">{f.productoSku}</td>
                    <td className="px-4 py-2">
                      <div className="flex items-center gap-2">
                        <span className="text-tinta-900">{f.productoNombre}</span>
                        {f.esExistenciaBaja && <Insignia tono="alerta">reponer</Insignia>}
                        {f.productoEstatus !== 'ACTIVO' &&
                          <Insignia tono={tonoEstatus[f.productoEstatus]}>{f.productoEstatus.toLowerCase()}</Insignia>}
                      </div>
                      <p className="text-2xs text-tinta-500">{f.categoriaNombre}</p>
                    </td>
                    <td className="px-4 py-2 font-mono text-2xs text-tinta-500">{f.localizador}</td>
                    <td className="px-4 py-2 text-right tabular-nums text-tinta-500">{f.cantidadReservada}</td>
                    <td className="px-4 py-2 text-right tabular-nums text-tinta-700">{f.cantidadDisponible}</td>
                    <td className="px-4 py-2">
                      {usuario && (
                        <AjusteRapido
                          productoId={f.productoId} almacenId={f.almacenId}
                          cantidadServidor={f.cantidadFisica} usuarioId={usuario.id}
                        />
                      )}
                    </td>
                    <td className="px-4 py-2 text-right">
                      <button
                        className="boton-sutil !py-1 !text-2xs" onClick={() => setAjustando(f)}
                        title="Ajustar a una cantidad exacta (conteo físico)"
                      >
                        <SlidersHorizontal className="h-3 w-3" /> Ajustar
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {data && <Paginador datos={data} alCambiar={setPagina} etiqueta="existencias" />}
        </div>
        {data && data.total > data.porPagina && (
          <p className="mt-2 text-2xs text-tinta-500">
            Exportar incluye los {new Intl.NumberFormat('es-MX').format(data.total)} registros
            que cumplen el filtro, no solo los {data.porPagina} de esta pagina.
          </p>
        )}
      </div>

      {ajustando && usuario && (
        <ModalAjuste fila={ajustando} usuarioId={usuario.id} alCerrar={() => setAjustando(null)} />
      )}
    </>
  )
}
