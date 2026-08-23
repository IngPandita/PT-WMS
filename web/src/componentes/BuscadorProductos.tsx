import { useEffect, useRef, useState } from 'react'
import clsx from 'clsx'
import { Check, Loader2, Search, X } from 'lucide-react'
import { ErrorApi, peticion } from '../lib/api'
import type { ProductoEncontrado } from '../lib/tipos'

interface Props {
  almacenId?: number | null
  seleccionado: ProductoEncontrado | null
  alSeleccionar: (p: ProductoEncontrado | null) => void
  placeholder?: string
  autoFocus?: boolean
}

const RETARDO_MS = 250

/**
 * Autocompletado de productos, reutilizable.
 *
 * Tres cosas que no son opcionales:
 *
 *   1. La selección devuelve el PRODUCTO, con su id real. El texto que el
 *      usuario tecleó nunca viaja como identificador.
 *   2. Una respuesta vieja no puede pisar a una más nueva. Cada búsqueda lleva
 *      su número de secuencia y se descarta si al volver ya no es la vigente;
 *      además se aborta la petición anterior, que es lo que hace que el
 *      indicador de carga sea honesto.
 *   3. El debounce evita una petición por tecla, pero no es una garantía de
 *      nada: si fallara, lo que protege el orden es el número de secuencia.
 */
export function BuscadorProductos({
  almacenId, seleccionado, alSeleccionar, placeholder = 'Buscar por SKU o nombre…', autoFocus,
}: Props) {
  const [texto, setTexto] = useState('')
  const [resultados, setResultados] = useState<ProductoEncontrado[]>([])
  const [abierto, setAbierto] = useState(false)
  const [cargando, setCargando] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [resaltado, setResaltado] = useState(0)

  const secuencia = useRef(0)
  const vigente = useRef(0)
  const abortar = useRef<AbortController | null>(null)
  const temporizador = useRef<number | null>(null)
  const contenedor = useRef<HTMLDivElement>(null)

  useEffect(() => () => {
    if (temporizador.current) window.clearTimeout(temporizador.current)
    abortar.current?.abort()
  }, [])

  // Cerrar al hacer clic fuera.
  useEffect(() => {
    const alClic = (e: MouseEvent) => {
      if (!contenedor.current?.contains(e.target as Node)) setAbierto(false)
    }
    document.addEventListener('mousedown', alClic)
    return () => document.removeEventListener('mousedown', alClic)
  }, [])

  const buscar = async (q: string) => {
    const mio = ++secuencia.current
    vigente.current = mio

    abortar.current?.abort()
    const control = new AbortController()
    abortar.current = control

    setCargando(true)
    setError(null)
    try {
      const parametros = new URLSearchParams({ q, limite: '15' })
      if (almacenId) parametros.set('almacenId', String(almacenId))
      const r = await peticion<ProductoEncontrado[]>(`/api/productos/buscar?${parametros}`, {
        señal: control.signal,
      })
      // Llegó tarde: ya hay una búsqueda más reciente. Se descarta.
      if (mio !== vigente.current) return
      setResultados(r)
      setResaltado(0)
    } catch (e) {
      if ((e as Error).name === 'AbortError') return
      if (mio !== vigente.current) return
      setError((e as ErrorApi).titulo ?? 'No se pudo buscar')
      setResultados([])
    } finally {
      if (mio === vigente.current) setCargando(false)
    }
  }

  const alEscribir = (valor: string) => {
    setTexto(valor)
    setAbierto(true)
    if (seleccionado) alSeleccionar(null)   // el usuario está cambiando de producto

    if (temporizador.current) window.clearTimeout(temporizador.current)
    if (valor.trim().length < 2) {
      setResultados([])
      setCargando(false)
      return
    }
    temporizador.current = window.setTimeout(() => buscar(valor.trim()), RETARDO_MS)
  }

  const elegir = (p: ProductoEncontrado) => {
    alSeleccionar(p)
    setTexto(`${p.sku} · ${p.nombre}`)
    setAbierto(false)
  }

  const alTeclear = (e: React.KeyboardEvent) => {
    if (!abierto || resultados.length === 0) return
    if (e.key === 'ArrowDown') { e.preventDefault(); setResaltado((i) => Math.min(i + 1, resultados.length - 1)) }
    if (e.key === 'ArrowUp')   { e.preventDefault(); setResaltado((i) => Math.max(i - 1, 0)) }
    if (e.key === 'Enter')     { e.preventDefault(); elegir(resultados[resaltado]) }
    if (e.key === 'Escape')    setAbierto(false)
  }

  const sinCoincidencias =
    abierto && !cargando && !error && texto.trim().length >= 2 && resultados.length === 0

  return (
    <div className="relative" ref={contenedor}>
      <div className="relative">
        <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-tinta-400" />
        <input
          className={clsx('campo pl-8 pr-8', seleccionado && 'border-emerald-300 bg-emerald-50/40')}
          placeholder={placeholder}
          value={texto}
          autoFocus={autoFocus}
          onChange={(e) => alEscribir(e.target.value)}
          onFocus={() => texto.trim().length >= 2 && setAbierto(true)}
          onKeyDown={alTeclear}
          role="combobox"
          aria-expanded={abierto}
          aria-autocomplete="list"
        />
        <span className="absolute right-2.5 top-1/2 -translate-y-1/2">
          {cargando ? <Loader2 className="h-3.5 w-3.5 animate-spin text-acento-600" />
           : seleccionado ? <Check className="h-3.5 w-3.5 text-emerald-600" />
           : texto ? (
             <button type="button" aria-label="Limpiar"
                     onClick={() => { setTexto(''); setResultados([]); alSeleccionar(null) }}>
               <X className="h-3.5 w-3.5 text-tinta-400 hover:text-tinta-600" />
             </button>
           ) : null}
        </span>
      </div>

      {texto.trim().length === 1 && (
        <p className="mt-1 text-2xs text-tinta-400">Escriba al menos dos caracteres.</p>
      )}

      {abierto && (resultados.length > 0 || sinCoincidencias || error) && (
        <ul role="listbox"
            className="absolute z-20 mt-1 max-h-64 w-full overflow-y-auto rounded-md border border-tinta-200 bg-white shadow-lg">
          {error && (
            <li className="px-3 py-2 text-sm text-rose-600">
              {error}
              <button type="button" className="ml-2 underline" onClick={() => buscar(texto.trim())}>
                Reintentar
              </button>
            </li>
          )}

          {sinCoincidencias && (
            <li className="px-3 py-3 text-center text-sm text-tinta-500">
              Ningún producto coincide con «{texto.trim()}».
            </li>
          )}

          {resultados.map((p, i) => (
            <li key={p.id} role="option" aria-selected={i === resaltado}>
              <button
                type="button"
                onMouseEnter={() => setResaltado(i)}
                onClick={() => elegir(p)}
                className={clsx('flex w-full items-center justify-between gap-3 px-3 py-1.5 text-left',
                  i === resaltado ? 'bg-acento-50' : 'hover:bg-tinta-50')}
              >
                <span className="min-w-0">
                  <span className="font-mono text-2xs text-tinta-600">{p.sku}</span>
                  <span className="block truncate text-sm text-tinta-900">{p.nombre}</span>
                  <span className="text-2xs text-tinta-400">{p.categoriaNombre}</span>
                </span>
                {p.cantidadDisponible != null && (
                  <span className={clsx('shrink-0 text-2xs tabular-nums',
                    p.cantidadDisponible > 0 ? 'text-tinta-500' : 'text-rose-600')}>
                    {p.cantidadDisponible} disp.
                  </span>
                )}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
