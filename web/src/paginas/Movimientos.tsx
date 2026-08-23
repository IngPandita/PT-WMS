import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import clsx from 'clsx'
import { Eye, RotateCcw } from 'lucide-react'
import { Encabezado } from '../App'
import { peticion } from '../lib/api'
import type { Almacen, FilaMovimiento, ProductoEncontrado, Usuario } from '../lib/tipos'
import { usarSesion } from '../hooks/usarSesion'
import { BuscadorProductos } from '../componentes/BuscadorProductos'
import { ModalMovimiento, USUARIO_SISTEMA } from '../componentes/ModalMovimiento'
import { EstadoVacio, Insignia, TablaSkeleton, tonoEstatus } from '../componentes/Base'
import { POR_PAGINA, Paginador, usarPaginaConFiltros, type Paginado } from '../componentes/Paginador'

const TIPOS = ['', 'ENTRADA', 'SALIDA', 'AJUSTE', 'RESERVA', 'LIBERACION', 'EMBARQUE', 'IMPORTACION', 'REVERSA']
const FECHA = new Intl.DateTimeFormat('es-MX', { dateStyle: 'short', timeStyle: 'medium' })

/** El rango por omisión es de 30 días, contados hacia atrás desde hoy. */
function rangoPorOmision() {
  const hoy = new Date()
  const hace30 = new Date(hoy)
  hace30.setDate(hoy.getDate() - 30)
  const iso = (d: Date) => d.toISOString().slice(0, 10)
  return { desde: iso(hace30), hasta: iso(hoy) }
}

export function PaginaMovimientos() {
  const { usuario } = usarSesion()
  const inicial = rangoPorOmision()

  const [tipo, setTipo] = useState('')
  const [almacenId, setAlmacenId] = useState<number | ''>('')
  const [usuarioId, setUsuarioId] = useState<number | ''>('')
  const [producto, setProducto] = useState<ProductoEncontrado | null>(null)
  const [desde, setDesde] = useState(inicial.desde)
  const [hasta, setHasta] = useState(inicial.hasta)
  const [seleccionado, setSeleccionado] = useState<FilaMovimiento | null>(null)
  const [verDetalle, setVerDetalle] = useState(false)

  const { data: almacenes = [] } = useQuery({
    queryKey: ['catalogo', 'almacenes'],
    queryFn: async () => (await peticion<{elementos: Almacen[]}>('/api/catalogos/almacenes')).elementos,
  })
  const { data: usuarios = [] } = useQuery({
    queryKey: ['catalogo', 'usuarios', 'todos'],
    queryFn: async () => (await peticion<{elementos: Usuario[]}>('/api/catalogos/usuarios?soloVigentes=false')).elementos,
  })

  const rangoInvalido = desde > hasta

  const filtros = new URLSearchParams({ desde, hasta })
  if (tipo) filtros.set('tipo', tipo)
  if (almacenId) filtros.set('almacenId', String(almacenId))
  if (usuarioId) filtros.set('usuarioId', String(usuarioId))
  // El filtro viaja con el identificador REAL del producto, no con el texto.
  if (producto) filtros.set('productoId', String(producto.id))

  const [pagina, setPagina] = usarPaginaConFiltros(filtros.toString())

  const p = new URLSearchParams(filtros)
  p.set('pagina', String(pagina))
  p.set('porPagina', String(POR_PAGINA))

  const { data, isLoading, isError } = useQuery({
    queryKey: ['movimientos', filtros.toString(), pagina],
    queryFn: () => peticion<Paginado<FilaMovimiento>>(`/api/inventario/movimientos?${p}`),
    enabled: !rangoInvalido,
    placeholderData: (previo) => previo,
  })
  const filas = data?.elementos

  const abrir = (m: FilaMovimiento) => { setSeleccionado(m); setVerDetalle(true) }

  return (
    <>
      <Encabezado
        titulo="Movimientos"
        descripcion="Bitácora de solo inserción. Cada renglón conserva su operación, su autor y su fecha."
        acciones={
          <>
            <button className="boton-secundario" disabled={!seleccionado}
                    onClick={() => seleccionado && setVerDetalle(true)}>
              <Eye className="h-3.5 w-3.5" /> Ver detalle
            </button>
            <button className="boton-secundario"
                    onClick={() => { const r = rangoPorOmision(); setDesde(r.desde); setHasta(r.hasta)
                                     setTipo(''); setAlmacenId(''); setUsuarioId(''); setProducto(null) }}>
              <RotateCcw className="h-3.5 w-3.5" /> Limpiar filtros
            </button>
          </>
        }
      />

      <div className="grid grid-cols-2 gap-2 border-b border-tinta-200 bg-white px-6 py-3 lg:grid-cols-6">
        <div className="lg:col-span-2">
          <label className="etiqueta mb-1 block">Producto</label>
          <BuscadorProductos seleccionado={producto} alSeleccionar={setProducto}
                             placeholder="SKU o nombre…" />
        </div>
        <div>
          <label className="etiqueta mb-1 block">Operador</label>
          <select className="campo" value={usuarioId}
                  onChange={(e) => setUsuarioId(e.target.value ? Number(e.target.value) : '')}>
            <option value="">Todos</option>
            {usuarios.map((u) => (
              <option key={u.id} value={u.id}>
                {u.codigo} · {u.nombre}{u.es_activo ? '' : ' (baja)'}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label className="etiqueta mb-1 block">Tipo</label>
          <select className="campo" value={tipo} onChange={(e) => setTipo(e.target.value)}>
            {TIPOS.map((t) => <option key={t} value={t}>{t === '' ? 'Todos' : t}</option>)}
          </select>
        </div>
        <div>
          <label className="etiqueta mb-1 block" htmlFor="desde">Desde</label>
          <input id="desde" type="date" className="campo" value={desde}
                 onChange={(e) => setDesde(e.target.value)} />
        </div>
        <div>
          <label className="etiqueta mb-1 block" htmlFor="hasta">Hasta</label>
          <input id="hasta" type="date" className="campo" value={hasta}
                 onChange={(e) => setHasta(e.target.value)} />
        </div>
        <div className="lg:col-span-2">
          <label className="etiqueta mb-1 block">Almacén</label>
          <select className="campo" value={almacenId}
                  onChange={(e) => setAlmacenId(e.target.value ? Number(e.target.value) : '')}>
            <option value="">Todos</option>
            {almacenes.map((a) => <option key={a.id} value={a.id}>{a.codigo}</option>)}
          </select>
        </div>
      </div>

      {rangoInvalido && (
        <p className="border-b border-rose-200 bg-rose-50 px-6 py-2 text-sm text-rose-700">
          La fecha inicial debe ser anterior o igual a la final.
        </p>
      )}

      <div className="p-6">
        <div className="tarjeta overflow-hidden">
          {rangoInvalido ? (
            <EstadoVacio titulo="Rango inválido" descripcion="Corrija las fechas para ver resultados." />
          ) : isLoading ? <TablaSkeleton columnas={8} />
          : isError ? (
            <EstadoVacio titulo="No se pudieron cargar los movimientos"
                         descripcion="Revise los filtros e intente de nuevo." />
          ) : !filas?.length ? (
            <EstadoVacio titulo="Sin movimientos"
                         descripcion="Ningún movimiento coincide con los filtros del periodo seleccionado." />
          ) : (
            <table className="w-full text-sm">
              <thead className="border-b border-tinta-200 bg-tinta-50/60">
                <tr className="[&>th]:px-4 [&>th]:py-2 [&>th]:text-left [&>th]:font-medium [&>th]:text-tinta-600">
                  <th>Fecha</th><th>Tipo</th><th>SKU</th><th>Alm.</th>
                  <th className="!text-right">Δ físico</th><th className="!text-right">Resultado</th>
                  <th>Operador</th><th>Origen</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-tinta-100">
                {filas.map((m) => (
                  <tr
                    key={m.id}
                    onClick={() => setSeleccionado(m)}
                    onDoubleClick={() => abrir(m)}
                    aria-selected={seleccionado?.id === m.id}
                    className={clsx('cursor-pointer',
                      seleccionado?.id === m.id
                        ? 'bg-acento-50 ring-1 ring-inset ring-acento-300'
                        : 'hover:bg-tinta-50/50',
                      m.estaDesactivado && 'opacity-60')}
                  >
                    <td className="px-4 py-2 text-2xs tabular-nums text-tinta-500">
                      {FECHA.format(new Date(m.creadoEn))}
                    </td>
                    <td className="px-4 py-2">
                      <Insignia tono={m.deltaFisica > 0 ? 'exito' : m.deltaFisica < 0 ? 'peligro' : 'info'}>
                        {m.tipoMovimiento.toLowerCase()}
                      </Insignia>
                      {m.estado !== 'APLICADO' && (
                        <span className="ml-1">
                          <Insignia tono={tonoEstatus[m.estado] ?? 'neutro'}>
                            {m.estado.toLowerCase()}
                          </Insignia>
                        </span>
                      )}
                    </td>
                    <td className={clsx('px-4 py-2 font-mono text-2xs text-tinta-600',
                                        m.estaDesactivado && 'line-through')}
                        title={m.productoNombre}>
                      {m.productoSku}
                    </td>
                    <td className="px-4 py-2 font-mono text-2xs text-tinta-500">{m.almacenCodigo}</td>
                    <td className="px-4 py-2 text-right tabular-nums font-medium">
                      {m.deltaFisica > 0 ? '+' : ''}{m.deltaFisica || '—'}
                    </td>
                    <td className="px-4 py-2 text-right text-2xs tabular-nums text-tinta-500">
                      {m.fisicaAntes} → {m.fisicaDespues}
                    </td>
                    <td className="px-4 py-2 text-2xs">
                      <span className={m.usuarioVigente ? 'text-tinta-700' : 'text-tinta-400 line-through'}>
                        {m.usuarioNombre}
                      </span>
                    </td>
                    <td className="px-4 py-2 text-2xs text-tinta-500">
                      {m.ordenFolio ?? m.tipoOrigen.toLowerCase()}
                      <p className="font-mono text-tinta-400" title={m.idOperacion}>
                        {m.idOperacion.slice(0, 22)}…
                      </p>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {data && <Paginador datos={data} alCambiar={setPagina} etiqueta="movimientos" />}
        </div>
        <p className="mt-2 text-2xs text-tinta-500">
          Un clic selecciona; doble clic abre el detalle. La tabla es de solo lectura: los datos de
          un movimiento no se editan.
          {usuario?.id === USUARIO_SISTEMA
            ? ' Como operador SISTEMA, puede desactivar un movimiento desde su detalle.'
            : ' Desactivar un movimiento está reservado al operador SISTEMA.'}
        </p>
      </div>

      {verDetalle && seleccionado && usuario && (
        <ModalMovimiento movimiento={seleccionado} usuarioId={usuario.id}
                         alCerrar={() => setVerDetalle(false)} />
      )}
    </>
  )
}
