import { useEffect, useState } from 'react'
import { NavLink, Navigate, Route, Routes } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import clsx from 'clsx'
import { BarChart3, Boxes, ClipboardList, History, Settings2, Upload } from 'lucide-react'
import { peticion } from './lib/api'
import type { Usuario } from './lib/tipos'
import { ContextoSesion } from './hooks/usarSesion'
import { ProveedorAvisos } from './componentes/Base'
import { PaginaTablero } from './paginas/Tablero'
import { PaginaInventario } from './paginas/Inventario'
import { PaginaOrdenes } from './paginas/Ordenes'
import { PaginaMovimientos } from './paginas/Movimientos'
import { PaginaImportacion } from './paginas/Importacion'
import { PaginaCatalogos } from './paginas/Catalogos'

const NAVEGACION = [
  { a: '/tablero',     icono: BarChart3,     texto: 'Tablero' },
  { a: '/inventario',  icono: Boxes,         texto: 'Inventario' },
  { a: '/ordenes',     icono: ClipboardList, texto: 'Órdenes' },
  { a: '/movimientos', icono: History,       texto: 'Movimientos' },
  { a: '/importacion', icono: Upload,        texto: 'Importación' },
  { a: '/catalogos',   icono: Settings2,     texto: 'Catálogos' },
]

export function App() {
  const [usuarioId, setUsuarioId] = useState<number | null>(null)

  const { data: usuarios = [] } = useQuery({
    queryKey: ['catalogo', 'usuarios'],
    queryFn: async () => (await peticion<{elementos: Usuario[]}>('/api/catalogos/usuarios')).elementos,
  })

  useEffect(() => {
    if (usuarioId === null && usuarios.length > 0) {
      const operador = usuarios.find((u) => u.rol !== 'SISTEMA' && u.es_activo) ?? usuarios[0]
      setUsuarioId(operador.id)
    }
  }, [usuarios, usuarioId])

  const usuario = usuarios.find((u) => u.id === usuarioId) ?? null

  return (
    <ContextoSesion.Provider value={{ usuario, usuarios, cambiarUsuario: setUsuarioId }}>
      <ProveedorAvisos>
        <div className="flex min-h-screen">
          <aside className="flex w-56 shrink-0 flex-col border-r border-tinta-200 bg-white">
            <div className="border-b border-tinta-200 px-4 py-4">
              <p className="text-sm font-semibold tracking-tight text-tinta-900">Mini WMS</p>
              <p className="text-2xs text-tinta-500">Inventario y órdenes</p>
            </div>

            <nav className="flex-1 space-y-0.5 p-2">
              {NAVEGACION.map(({ a, icono: Icono, texto }) => (
                <NavLink
                  key={a} to={a}
                  className={({ isActive }) =>
                    clsx('flex items-center gap-2 rounded-md px-2.5 py-1.5 text-sm transition',
                      isActive ? 'bg-tinta-100 font-medium text-tinta-900'
                               : 'text-tinta-600 hover:bg-tinta-50 hover:text-tinta-900')}
                >
                  <Icono className="h-4 w-4" strokeWidth={1.75} />
                  {texto}
                </NavLink>
              ))}
            </nav>

            <div className="border-t border-tinta-200 p-3">
              <label className="etiqueta mb-1 block" htmlFor="operador">Operador activo</label>
              <select
                id="operador" className="campo text-sm"
                value={usuarioId ?? ''}
                onChange={(e) => setUsuarioId(Number(e.target.value))}
              >
                {usuarios.map((u) => (
                  <option key={u.id} value={u.id} disabled={!u.es_activo}>
                    {u.codigo} · {u.nombre}{u.es_activo ? '' : ' (inactivo)'}
                  </option>
                ))}
              </select>
              <p className="mt-1.5 text-2xs leading-snug text-tinta-500">
                Toda mutación se atribuye a este operador. Cambiarlo invalida las
                intenciones en vuelo.
              </p>
            </div>
          </aside>

          <main className="min-w-0 flex-1 overflow-x-hidden">
            <Routes>
              <Route path="/" element={<Navigate to="/tablero" replace />} />
              <Route path="/tablero" element={<PaginaTablero />} />
              <Route path="/inventario" element={<PaginaInventario />} />
              <Route path="/ordenes" element={<PaginaOrdenes />} />
              <Route path="/movimientos" element={<PaginaMovimientos />} />
              <Route path="/importacion" element={<PaginaImportacion />} />
              <Route path="/catalogos" element={<PaginaCatalogos />} />
            </Routes>
          </main>
        </div>
      </ProveedorAvisos>
    </ContextoSesion.Provider>
  )
}

export function Encabezado({ titulo, descripcion, acciones }: {
  titulo: string; descripcion: string; acciones?: React.ReactNode
}) {
  return (
    <header className="flex items-start justify-between gap-4 border-b border-tinta-200 bg-white px-6 py-4">
      <div>
        <h1 className="text-base font-semibold tracking-tight text-tinta-900">{titulo}</h1>
        <p className="mt-0.5 text-sm text-tinta-500">{descripcion}</p>
      </div>
      {acciones && <div className="flex shrink-0 items-center gap-2">{acciones}</div>}
    </header>
  )
}
