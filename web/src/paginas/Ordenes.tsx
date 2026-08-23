import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Plus } from 'lucide-react'
import { Encabezado } from '../App'
import { ErrorApi, acunarIdOperacion, peticion } from '../lib/api'
import type { Almacen, Cliente, FilaOrden, FilaPartida, ProductoEncontrado } from '../lib/tipos'
import { BuscadorProductos } from '../componentes/BuscadorProductos'
import { usarSesion } from '../hooks/usarSesion'
import { Cargando, EstadoVacio, Insignia, Modal, TablaSkeleton, tonoEstatus, usarAvisos } from '../componentes/Base'
import { POR_PAGINA, Paginador, usarPaginaConFiltros, type Paginado } from '../componentes/Paginador'

const MONEDA = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN' })
const ESTATUS = ['', 'BORRADOR', 'CONFIRMADA', 'ENVIADA', 'CANCELADA']

export function PaginaOrdenes() {
  const { usuario } = usarSesion()
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()
  const [filtro, setFiltro] = useState('')
  const [abierta, setAbierta] = useState<FilaOrden | null>(null)
  const [creando, setCreando] = useState(false)

  const [pagina, setPagina] = usarPaginaConFiltros(filtro)
  const { data, isLoading } = useQuery({
    queryKey: ['ordenes', filtro, pagina],
    queryFn: () => peticion<Paginado<FilaOrden>>(
      `/api/ordenes?pagina=${pagina}&porPagina=${POR_PAGINA}${filtro ? `&estatus=${filtro}` : ''}`),
    placeholderData: (previo) => previo,
  })
  const ordenes = data?.elementos

  /**
   * Cada acción acuña su id al pulsarse y lo conserva si falla, de modo que
   * reintentar sea seguro: el backend reconoce el reenvío y no aplica dos veces.
   */
  const accion = useMutation({
    mutationFn: async ({ orden, verbo, motivo, idOperacion }:
      { orden: FilaOrden; verbo: string; motivo?: string; idOperacion: string }) =>
      peticion<FilaOrden & { fueReenvio: boolean }>(`/api/ordenes/${orden.id}/${verbo}`, {
        metodo: 'POST',
        cuerpo: verbo === 'cancelar' ? { motivo } : {},
        idOperacion, usuarioId: usuario!.id, alcance: `orden:${verbo}:${orden.id}`,
      }),
    onSuccess: (r) => {
      avisar({
        tono: 'exito',
        texto: `${r.folio} · ${r.estatus.toLowerCase()}`,
        detalle: r.fueReenvio ? 'Era un reenvío: se devolvió el resultado original.' : undefined,
      })
      clienteQuery.invalidateQueries({ queryKey: ['ordenes'] })
      clienteQuery.invalidateQueries({ queryKey: ['inventario'] })
      clienteQuery.invalidateQueries({ queryKey: ['indicadores'] })
      setAbierta(null)
    },
    onError: (e: ErrorApi) => avisar({ tono: 'error', texto: e.titulo, detalle: e.detalle ?? undefined }),
  })

  const ejecutar = (orden: FilaOrden, verbo: string) => {
    const motivo = verbo === 'cancelar'
      ? window.prompt('Motivo de la cancelación (queda en el historial):') ?? ''
      : undefined
    if (verbo === 'cancelar' && !motivo?.trim()) return
    accion.mutate({ orden, verbo, motivo, idOperacion: acunarIdOperacion(`orden${verbo}`) })
  }

  return (
    <>
      <Encabezado
        titulo="Órdenes" descripcion="Confirmar reserva, enviar descuenta, cancelar libera."
        acciones={
          <button className="boton-primario" onClick={() => setCreando(true)} disabled={!usuario}>
            <Plus className="h-3.5 w-3.5" /> Nueva orden
          </button>
        }
      />

      <div className="flex items-center gap-2 border-b border-tinta-200 bg-white px-6 py-3">
        {ESTATUS.map((e) => (
          <button key={e} onClick={() => setFiltro(e)}
            className={filtro === e ? 'boton bg-tinta-900 text-white' : 'boton-secundario'}>
            {e === '' ? 'Todas' : e.charAt(0) + e.slice(1).toLowerCase()}
          </button>
        ))}
      </div>

      <div className="p-6">
        <div className="tarjeta overflow-hidden">
          {isLoading ? <TablaSkeleton columnas={7} />
          : !ordenes?.length ? (
            <EstadoVacio titulo="Sin órdenes" descripcion="No hay órdenes con ese filtro. Cree una para empezar." />
          ) : (
            <table className="w-full text-sm">
              <thead className="border-b border-tinta-200 bg-tinta-50/60">
                <tr className="[&>th]:px-4 [&>th]:py-2 [&>th]:text-left [&>th]:font-medium [&>th]:text-tinta-600">
                  <th>Folio</th><th>Cliente</th><th>Almacén</th><th>Estatus</th>
                  <th className="!text-right">Partidas</th><th className="!text-right">Total</th><th />
                </tr>
              </thead>
              <tbody className="divide-y divide-tinta-100">
                {ordenes.map((o) => (
                  <tr key={o.id} className="cursor-pointer hover:bg-tinta-50/50" onClick={() => setAbierta(o)}>
                    <td className="px-4 py-2 font-mono text-2xs text-tinta-700">{o.folio}</td>
                    <td className="px-4 py-2 text-tinta-800">{o.clienteNombre}</td>
                    <td className="px-4 py-2 font-mono text-2xs text-tinta-500">{o.almacenCodigo}</td>
                    <td className="px-4 py-2"><Insignia tono={tonoEstatus[o.estatus]}>{o.estatus.toLowerCase()}</Insignia></td>
                    <td className="px-4 py-2 text-right tabular-nums text-tinta-600">{o.partidas}</td>
                    <td className="px-4 py-2 text-right tabular-nums font-medium">{MONEDA.format(o.montoTotal)}</td>
                    <td className="px-4 py-2 text-right" onClick={(e) => e.stopPropagation()}>
                      <div className="flex justify-end gap-1">
                        {o.estatus === 'BORRADOR' && (
                          <button className="boton-secundario !py-1 !text-2xs"
                                  onClick={() => ejecutar(o, 'confirmar')}>Confirmar</button>
                        )}
                        {o.estatus === 'CONFIRMADA' && (
                          <button className="boton-secundario !py-1 !text-2xs"
                                  onClick={() => ejecutar(o, 'enviar')}>Enviar</button>
                        )}
                        {(o.estatus === 'BORRADOR' || o.estatus === 'CONFIRMADA') && (
                          <button className="boton-sutil !py-1 !text-2xs text-rose-600"
                                  onClick={() => ejecutar(o, 'cancelar')}>Cancelar</button>
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {data && <Paginador datos={data} alCambiar={setPagina} etiqueta="órdenes" />}
        </div>
      </div>

      {abierta && <DetalleOrden orden={abierta} alCerrar={() => setAbierta(null)} />}
      {creando && <NuevaOrden alCerrar={() => setCreando(false)} />}
      {accion.isPending && <div className="fixed bottom-4 left-4"><Cargando etiqueta="Aplicando…" /></div>}
    </>
  )
}

function DetalleOrden({ orden, alCerrar }: { orden: FilaOrden; alCerrar: () => void }) {
  const { data: partidas } = useQuery({
    queryKey: ['partidas', orden.id],
    queryFn: () => peticion<FilaPartida[]>(`/api/ordenes/${orden.id}/partidas`),
  })

  return (
    <Modal abierto alCerrar={alCerrar} titulo={orden.folio}
           descripcion={`${orden.clienteNombre} · ${orden.almacenCodigo} · creada por ${orden.creadoPorNombre}`}>
      <table className="w-full text-sm">
        <thead>
          <tr className="[&>th]:pb-1.5 [&>th]:text-left [&>th]:text-2xs [&>th]:font-medium [&>th]:uppercase [&>th]:text-tinta-500">
            <th>SKU</th><th>Producto</th><th className="!text-right">Cant.</th>
            <th className="!text-right">Precio</th><th className="!text-right">Importe</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-tinta-100">
          {partidas?.map((p) => (
            <tr key={p.id}>
              <td className="py-1.5 font-mono text-2xs text-tinta-600">{p.productoSku}</td>
              <td className="py-1.5 text-tinta-800">{p.productoNombre}</td>
              <td className="py-1.5 text-right tabular-nums">{p.cantidad}</td>
              <td className="py-1.5 text-right tabular-nums text-tinta-600">{MONEDA.format(p.precioUnitarioHistorico)}</td>
              <td className="py-1.5 text-right tabular-nums font-medium">{MONEDA.format(p.importeLinea)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="mt-3 text-2xs leading-snug text-tinta-500">
        El precio mostrado es el que tenía el producto al capturar la orden. Cambiar el
        catálogo no reescribe una orden ya capturada.
      </p>
      {orden.motivoCancelacion && (
        <p className="mt-2 rounded bg-rose-50 px-2 py-1.5 text-2xs text-rose-700">
          Cancelada: {orden.motivoCancelacion}
        </p>
      )}
    </Modal>
  )
}

function NuevaOrden({ alCerrar }: { alCerrar: () => void }) {
  const { usuario } = usarSesion()
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()

  const { data: clientes = [] } = useQuery({ queryKey: ['catalogo', 'clientes'],
    queryFn: async () => (await peticion<{elementos: Cliente[]}>('/api/catalogos/clientes')).elementos })
  const { data: almacenes = [] } = useQuery({ queryKey: ['catalogo', 'almacenes'],
    queryFn: async () => (await peticion<{elementos: Almacen[]}>('/api/catalogos/almacenes')).elementos })
  const [clienteId, setClienteId] = useState<number | ''>('')
  const [almacenId, setAlmacenId] = useState<number | ''>('')
  // Cada partida guarda el PRODUCTO completo, no un texto: el id real es lo
  // unico que viaja al backend.
  const [partidas, setPartidas] = useState<{ producto: ProductoEncontrado | null; cantidad: number }[]>([
    { producto: null, cantidad: 1 },
  ])
  // El id se acuña al ABRIR el modal y se reutiliza en cada intento de guardar.
  const [idOperacion] = useState(() => acunarIdOperacion('ordenalta'))

  const crear = useMutation({
    mutationFn: () => peticion<FilaOrden>('/api/ordenes', {
      metodo: 'POST',
      cuerpo: {
        clienteId, almacenId, notas: null,
        partidas: partidas.filter((p) => p.producto !== null)
          .map((p) => ({ productoId: p.producto!.id, cantidad: p.cantidad })),
      },
      idOperacion, usuarioId: usuario!.id, alcance: 'orden:alta',
    }),
    onSuccess: (r) => {
      avisar({ tono: 'exito', texto: `Orden ${r.folio} creada` })
      clienteQuery.invalidateQueries({ queryKey: ['ordenes'] })
      alCerrar()
    },
    onError: (e: ErrorApi) => avisar({
      tono: 'error', texto: e.titulo,
      detalle: (e.detalle ?? '') + ' Puede reintentar: se reenviará la misma operación.',
    }),
  })

  const listo = clienteId !== '' && almacenId !== '' && partidas.some((p) => p.producto !== null)

  return (
    <Modal abierto alCerrar={alCerrar} titulo="Nueva orden"
           descripcion="Reintentar es seguro: la orden lleva un identificador de operación único."
           pie={
             <>
               <button className="boton-secundario" onClick={alCerrar}>Cancelar</button>
               <button className="boton-primario" disabled={!listo || crear.isPending}
                       onClick={() => crear.mutate()}>
                 {crear.isPending ? 'Creando…' : 'Crear orden'}
               </button>
             </>
           }>
      <div className="space-y-3">
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="etiqueta mb-1 block">Cliente</label>
            <select className="campo" value={clienteId}
                    onChange={(e) => setClienteId(Number(e.target.value))}>
              <option value="">Seleccione…</option>
              {clientes.map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
          </div>
          <div>
            <label className="etiqueta mb-1 block">Almacén</label>
            <select className="campo" value={almacenId}
                    onChange={(e) => setAlmacenId(Number(e.target.value))}>
              <option value="">Seleccione…</option>
              {almacenes.map((a) => <option key={a.id} value={a.id}>{a.codigo} · {a.nombre}</option>)}
            </select>
          </div>
        </div>

        <div>
          <label className="etiqueta mb-1 block">Partidas</label>
          <div className="space-y-1.5">
            {partidas.map((p, i) => (
              <div key={i} className="flex gap-2">
                <div className="flex-1">
                  <BuscadorProductos
                    almacenId={almacenId === '' ? null : almacenId}
                    seleccionado={p.producto}
                    alSeleccionar={(pr) => setPartidas((xs) => xs.map((x, j) =>
                      j === i ? { ...x, producto: pr } : x))}
                  />
                </div>
                <input type="number" min={1} className="campo w-20" value={p.cantidad}
                       onChange={(e) => setPartidas((xs) => xs.map((x, j) =>
                         j === i ? { ...x, cantidad: Math.max(1, Number(e.target.value)) } : x))} />
                {partidas.length > 1 && (
                  <button className="boton-sutil" onClick={() =>
                    setPartidas((xs) => xs.filter((_, j) => j !== i))}>×</button>
                )}
              </div>
            ))}
          </div>
          <button className="boton-sutil mt-1.5 !text-2xs"
                  onClick={() => setPartidas((xs) => [...xs, { producto: null, cantidad: 1 }])}>
            + Agregar partida
          </button>
        </div>
      </div>
    </Modal>
  )
}
