import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import clsx from 'clsx'
import { Pencil, Plus, RotateCcw, Ban } from 'lucide-react'
import { Encabezado } from '../App'
import { peticion } from '../lib/api'
import { EstadoVacio, Insignia, TablaSkeleton, tonoEstatus } from '../componentes/Base'
import { POR_PAGINA, Paginador, usarPaginaConFiltros, type Paginado } from '../componentes/Paginador'
import { usarSesion } from '../hooks/usarSesion'
import {
  ModalCatalogo, ModalVigenciaCatalogo, USUARIO_SISTEMA, type RegistroCatalogo,
} from '../componentes/ModalCatalogo'

/**
 * `vigencia` nombra la columna que expresa si el registro sigue en uso.
 * Cuatro catálogos usan un booleano; productos usa `estatus` con tres
 * valores porque distinguir INACTIVO de DESCONTINUADO tiene sentido de
 * negocio. La excepción se declara aquí, no se adivina fila por fila.
 */
const RECURSOS = [
  { clave: 'categorias', texto: 'Categorías', vigencia: 'es_activo',
    ayuda: 'El código de 4 letras es el prefijo del SKU. Se puede corregir mientras la categoría no haya acuñado ningún producto; después el motor lo congela.' },
  { clave: 'almacenes',  texto: 'Almacenes',  vigencia: 'es_activo',
    ayuda: 'El código es de longitud fija y NO forma parte del SKU: es un localizador, y por eso sí se puede reubicar.' },
  { clave: 'productos',  texto: 'Productos',  vigencia: 'estatus',
    ayuda: 'El SKU lo acuña el motor y queda congelado. Recategorizar un producto no lo reescribe.' },
  { clave: 'clientes',   texto: 'Clientes',   vigencia: 'es_activo',
    ayuda: 'El código es opaco: no incorpora el nombre comercial, que sí puede cambiar y sí se edita.' },
  { clave: 'usuarios',   texto: 'Operadores', vigencia: 'es_activo',
    ayuda: 'Sin credenciales. Existen para atribuir cada movimiento; la baja es lógica y auditada. El rol solo lo cambia el operador SISTEMA.' },
] as const

type Recurso = (typeof RECURSOS)[number]

const OCULTAS = new Set([
  'desactivado_por_usuario_id', 'consecutivo', 'consecutivo_sku',
  'sku_prefijo', 'sku_consecutivo', 'version_concurrencia', 'actualizado_en',
])

/** Un registro sigue en uso si su columna de vigencia lo dice. */
const estaVigente = (fila: RegistroCatalogo, recurso: Recurso) =>
  recurso.vigencia === 'estatus' ? fila.estatus === 'ACTIVO' : fila.es_activo === true

export function PaginaCatalogos() {
  const [recurso, setRecurso] = useState<Recurso>(RECURSOS[0])
  const [seleccionado, setSeleccionado] = useState<RegistroCatalogo | null>(null)
  const [dandoAlta, setDandoAlta] = useState(false)
  const [editando, setEditando] = useState(false)
  const [cambiandoVigencia, setCambiandoVigencia] = useState(false)
  const { usuario } = usarSesion()
  const [pagina, setPagina] = usarPaginaConFiltros(recurso.clave)

  const { data, isLoading } = useQuery({
    queryKey: ['catalogo', recurso.clave, 'todos', pagina],
    queryFn: () => peticion<Paginado<RegistroCatalogo>>(
      `/api/catalogos/${recurso.clave}?soloVigentes=false&pagina=${pagina}&porPagina=${POR_PAGINA}`),
    placeholderData: (previo) => previo,
  })
  const filas = data?.elementos

  // Solo el alta está reservada al operador SISTEMA. Corregir y dar de baja
  // los puede hacer cualquier operador identificado: es lo que el motor
  // impone, y la asimetría está documentada en la especificación (§3.11).
  // Ocultar el botón es cortesía; la API rechaza igual.
  const puedeDarAlta = usuario?.id === USUARIO_SISTEMA

  // La fila seleccionada se vuelve a leer del listado: tras guardar, la que
  // está en memoria trae la versión de concurrencia vieja y el siguiente
  // guardado chocaría contra sí mismo.
  const vigente = filas?.find((f) => f.id === seleccionado?.id) ?? null
  const columnas = filas?.length ? Object.keys(filas[0]).filter((c) => !OCULTAS.has(c)) : []

  const cambiarRecurso = (r: Recurso) => { setRecurso(r); setSeleccionado(null) }

  return (
    <>
      <Encabezado
        titulo="Catálogos" descripcion="Datos de referencia del sistema."
        acciones={
          <>
            <button className="boton-secundario" disabled={!vigente}
                    onClick={() => setEditando(true)}>
              <Pencil className="h-3.5 w-3.5" /> Corregir
            </button>

            {vigente && !estaVigente(vigente, recurso) ? (
              <button className="boton-secundario" onClick={() => setCambiandoVigencia(true)}>
                <RotateCcw className="h-3.5 w-3.5" /> Reactivar
              </button>
            ) : (
              <button className="boton-secundario" disabled={!vigente}
                      onClick={() => setCambiandoVigencia(true)}>
                <Ban className="h-3.5 w-3.5" /> Dar de baja
              </button>
            )}

            {puedeDarAlta ? (
              <button className="boton-primario" onClick={() => setDandoAlta(true)}>
                <Plus className="h-3.5 w-3.5" /> Nuevo
              </button>
            ) : (
              <span className="text-2xs text-tinta-400">
                El alta en catálogos está reservada al operador SISTEMA
              </span>
            )}
          </>
        }
      />

      <div className="flex items-center gap-2 border-b border-tinta-200 bg-white px-6 py-3">
        {RECURSOS.map((r) => (
          <button key={r.clave} onClick={() => cambiarRecurso(r)}
                  className={recurso.clave === r.clave ? 'boton bg-tinta-900 text-white' : 'boton-secundario'}>
            {r.texto}
          </button>
        ))}
      </div>

      <div className="p-6">
        <p className="mb-3 text-sm text-tinta-500">{recurso.ayuda}</p>
        <div className="tarjeta overflow-x-auto">
          {isLoading ? <TablaSkeleton columnas={5} />
          : !filas?.length ? <EstadoVacio titulo="Catálogo vacío" descripcion="No hay registros que mostrar." />
          : (
            <table className="w-full text-sm">
              <thead className="border-b border-tinta-200 bg-tinta-50/60">
                <tr>
                  {columnas.map((c) => (
                    <th key={c} className="whitespace-nowrap px-4 py-2 text-left font-medium text-tinta-600">
                      {c.replaceAll('_', ' ')}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-tinta-100">
                {filas.map((f) => (
                  <tr
                    key={String(f.id)}
                    onClick={() => setSeleccionado(f)}
                    onDoubleClick={() => { setSeleccionado(f); setEditando(true) }}
                    aria-selected={seleccionado?.id === f.id}
                    className={clsx('cursor-pointer',
                      seleccionado?.id === f.id
                        ? 'bg-acento-50 ring-1 ring-inset ring-acento-300'
                        : 'hover:bg-tinta-50/50',
                      !estaVigente(f, recurso) && 'opacity-60')}
                  >
                    {columnas.map((c) => (
                      <td key={c} className="whitespace-nowrap px-4 py-2 text-tinta-700">
                        {formatear(c, f[c])}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {data && <Paginador datos={data} alCambiar={setPagina} etiqueta="registros" />}
        </div>
        <p className="mt-2 text-2xs text-tinta-500">
          Un clic selecciona; doble clic abre la corrección. La baja es lógica: el registro
          conserva su historia y se puede reactivar, y el sello de quién y cuándo no se borra.
        </p>
      </div>

      {dandoAlta && puedeDarAlta && usuario && (
        <ModalCatalogo recurso={recurso.clave} etiqueta={recurso.texto}
                       usuarioId={usuario.id} alCerrar={() => setDandoAlta(false)} />
      )}

      {editando && vigente && usuario && (
        <ModalCatalogo recurso={recurso.clave} etiqueta={recurso.texto} registro={vigente}
                       usuarioId={usuario.id} alCerrar={() => setEditando(false)} />
      )}

      {cambiandoVigencia && vigente && usuario && (
        <ModalVigenciaCatalogo recurso={recurso.clave} etiqueta={recurso.texto} registro={vigente}
                               vigente={estaVigente(vigente, recurso)} usuarioId={usuario.id}
                               alCerrar={() => setCambiandoVigencia(false)} />
      )}
    </>
  )
}

function formatear(columna: string, valor: unknown) {
  if (valor === null || valor === undefined) return <span className="text-tinta-300">—</span>
  if (typeof valor === 'boolean')
    return <Insignia tono={valor ? 'exito' : 'neutro'}>{valor ? 'vigente' : 'dado de baja'}</Insignia>
  if (columna === 'estatus')
    return <Insignia tono={tonoEstatus[String(valor)] ?? 'neutro'}>{String(valor).toLowerCase()}</Insignia>
  if (columna === 'sku' || columna === 'codigo')
    return <span className="font-mono text-2xs">{String(valor)}</span>
  if (columna.endsWith('_en'))
    return <span className="text-2xs tabular-nums text-tinta-500">
      {new Date(String(valor)).toLocaleString('es-MX')}</span>
  return String(valor)
}
