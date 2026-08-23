import { useEffect, useRef, useState } from 'react'
import clsx from 'clsx'
import { ChevronLeft, ChevronRight } from 'lucide-react'

/** Envoltura que devuelve la API para cualquier listado paginado. */
export interface Paginado<T> {
  elementos: T[]
  total: number
  numeroPagina: number
  porPagina: number
  totalPaginas: number
  hayAnterior: boolean
  haySiguiente: boolean
}

export const POR_PAGINA = 25

const NUMERO = new Intl.NumberFormat('es-MX')

/**
 * Reinicia la página a 1 cuando cambia cualquier filtro.
 *
 * Sin esto, estar en la página 7 y aplicar un filtro que devuelve 2 páginas
 * mostraría una lista vacía sin explicación aparente. La comparación es sobre
 * la clave serializada de los filtros, no sobre cada uno por separado.
 */
export function usarPaginaConFiltros(claveFiltros: string) {
  const [pagina, setPagina] = useState(1)
  const anterior = useRef(claveFiltros)

  useEffect(() => {
    if (anterior.current !== claveFiltros) {
      anterior.current = claveFiltros
      setPagina(1)
    }
  }, [claveFiltros])

  return [pagina, setPagina] as const
}

export function Paginador({
  datos, alCambiar, etiqueta = 'registros',
}: {
  datos: Pick<Paginado<unknown>, 'total' | 'numeroPagina' | 'porPagina' | 'totalPaginas' | 'hayAnterior' | 'haySiguiente'>
  alCambiar: (pagina: number) => void
  etiqueta?: string
}) {
  const { total, numeroPagina, porPagina, totalPaginas, hayAnterior, haySiguiente } = datos
  if (total === 0) return null

  const desde = (numeroPagina - 1) * porPagina + 1
  const hasta = Math.min(numeroPagina * porPagina, total)

  return (
    <nav className="flex items-center justify-between border-t border-tinta-200 px-4 py-2.5"
         aria-label="Paginación">
      <p className="text-2xs tabular-nums text-tinta-500">
        {NUMERO.format(desde)}–{NUMERO.format(hasta)} de{' '}
        <strong className="font-medium text-tinta-700">{NUMERO.format(total)}</strong> {etiqueta}
      </p>

      <div className="flex items-center gap-1">
        <button className="boton-sutil !px-1.5" disabled={!hayAnterior}
                onClick={() => alCambiar(numeroPagina - 1)} aria-label="Página anterior">
          <ChevronLeft className="h-3.5 w-3.5" />
        </button>

        {paginasVisibles(numeroPagina, totalPaginas).map((p, i) =>
          p === null ? (
            <span key={`s${i}`} className="px-1 text-2xs text-tinta-400">…</span>
          ) : (
            <button
              key={p} onClick={() => alCambiar(p)}
              aria-current={p === numeroPagina ? 'page' : undefined}
              className={clsx('boton min-w-[1.75rem] !px-1.5 !py-1 !text-2xs tabular-nums',
                p === numeroPagina
                  ? 'bg-tinta-900 text-white'
                  : 'text-tinta-600 hover:bg-tinta-100')}
            >
              {p}
            </button>
          ))}

        <button className="boton-sutil !px-1.5" disabled={!haySiguiente}
                onClick={() => alCambiar(numeroPagina + 1)} aria-label="Página siguiente">
          <ChevronRight className="h-3.5 w-3.5" />
        </button>
      </div>
    </nav>
  )
}

/** Primera, última, y una ventana alrededor de la actual. `null` = elipsis. */
function paginasVisibles(actual: number, total: number): (number | null)[] {
  if (total <= 7) return Array.from({ length: total }, (_, i) => i + 1)

  const set = new Set<number>([1, total, actual])
  if (actual - 1 > 1) set.add(actual - 1)
  if (actual + 1 < total) set.add(actual + 1)
  if (actual <= 3) { set.add(2); set.add(3); set.add(4) }
  if (actual >= total - 2) { set.add(total - 1); set.add(total - 2); set.add(total - 3) }

  const ordenadas = [...set].filter((p) => p >= 1 && p <= total).sort((a, b) => a - b)
  const salida: (number | null)[] = []
  for (let i = 0; i < ordenadas.length; i++) {
    if (i > 0 && ordenadas[i] - ordenadas[i - 1] > 1) salida.push(null)
    salida.push(ordenadas[i])
  }
  return salida
}
