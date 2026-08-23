import { createContext, useContext, useState, type ReactNode } from 'react'
import clsx from 'clsx'
import { AlertCircle, CheckCircle2, Inbox, Loader2, X } from 'lucide-react'

// =====================================================================
//  Primitivas de interfaz
// =====================================================================

export function Skeleton({ className }: { className?: string }) {
  return <div className={clsx('animate-pulse rounded bg-tinta-200/70', className)} />
}

export function TablaSkeleton({ filas = 6, columnas = 5 }: { filas?: number; columnas?: number }) {
  return (
    <div className="space-y-px" aria-hidden>
      {Array.from({ length: filas }).map((_, f) => (
        <div key={f} className="flex gap-3 px-4 py-3">
          {Array.from({ length: columnas }).map((_, c) => (
            <Skeleton key={c} className={clsx('h-4', c === 0 ? 'w-32' : 'w-20')} />
          ))}
        </div>
      ))}
    </div>
  )
}

export function EstadoVacio({
  titulo, descripcion, accion,
}: { titulo: string; descripcion: string; accion?: ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-6 py-16 text-center">
      <Inbox className="h-8 w-8 text-tinta-300" strokeWidth={1.5} />
      <p className="text-sm font-medium text-tinta-700">{titulo}</p>
      <p className="max-w-sm text-sm text-tinta-500">{descripcion}</p>
      {accion && <div className="mt-2">{accion}</div>}
    </div>
  )
}

export function Insignia({
  children, tono = 'neutro',
}: { children: ReactNode; tono?: 'neutro' | 'exito' | 'alerta' | 'peligro' | 'info' }) {
  const tonos = {
    neutro:  'bg-tinta-100 text-tinta-700',
    exito:   'bg-emerald-50 text-emerald-700',
    alerta:  'bg-amber-50 text-amber-700',
    peligro: 'bg-rose-50 text-rose-700',
    info:    'bg-acento-50 text-acento-700',
  }
  return (
    <span className={clsx('inline-flex items-center rounded px-1.5 py-0.5 text-2xs font-medium', tonos[tono])}>
      {children}
    </span>
  )
}

export const tonoEstatus: Record<string, 'neutro' | 'exito' | 'alerta' | 'peligro' | 'info'> = {
  BORRADOR: 'neutro', CONFIRMADA: 'info', ENVIADA: 'exito', CANCELADA: 'peligro',
  ACTIVO: 'exito', INACTIVO: 'neutro', DESCONTINUADO: 'peligro',
  OK: 'exito', ERROR: 'peligro', OMITIDO: 'alerta',
  COMPLETADO: 'exito', COMPLETADO_CON_ERRORES: 'alerta', FALLIDO: 'peligro', PROCESANDO: 'info',
}

// =====================================================================
//  Avisos
// =====================================================================

interface Aviso { id: number; tono: 'exito' | 'error'; texto: string; detalle?: string }
const ContextoAvisos = createContext<(a: Omit<Aviso, 'id'>) => void>(() => {})
export const usarAvisos = () => useContext(ContextoAvisos)

export function ProveedorAvisos({ children }: { children: ReactNode }) {
  const [avisos, setAvisos] = useState<Aviso[]>([])

  const avisar = (a: Omit<Aviso, 'id'>) => {
    const id = Date.now() + Math.random()
    setAvisos((xs) => [...xs, { ...a, id }])
    setTimeout(() => setAvisos((xs) => xs.filter((x) => x.id !== id)), 6000)
  }

  return (
    <ContextoAvisos.Provider value={avisar}>
      {children}
      <div className="pointer-events-none fixed bottom-4 right-4 z-50 flex w-80 flex-col gap-2">
        {avisos.map((a) => (
          <div
            key={a.id}
            role="status"
            className={clsx(
              'pointer-events-auto flex items-start gap-2 rounded-lg border bg-white px-3 py-2.5 shadow-sm',
              a.tono === 'exito' ? 'border-emerald-200' : 'border-rose-200',
            )}
          >
            {a.tono === 'exito'
              ? <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-600" />
              : <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-rose-600" />}
            <div className="min-w-0 flex-1">
              <p className="text-sm font-medium text-tinta-800">{a.texto}</p>
              {a.detalle && <p className="mt-0.5 text-2xs leading-snug text-tinta-500">{a.detalle}</p>}
            </div>
            <button
              onClick={() => setAvisos((xs) => xs.filter((x) => x.id !== a.id))}
              className="text-tinta-400 hover:text-tinta-600" aria-label="Cerrar aviso"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          </div>
        ))}
      </div>
    </ContextoAvisos.Provider>
  )
}

// =====================================================================
//  Modal
// =====================================================================

export function Modal({
  abierto, alCerrar, titulo, descripcion, children, pie,
}: {
  abierto: boolean; alCerrar: () => void; titulo: string
  descripcion?: string; children: ReactNode; pie?: ReactNode
}) {
  if (!abierto) return null
  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-tinta-950/30 p-4"
         onClick={alCerrar} role="presentation">
      <div className="w-full max-w-lg rounded-lg border border-tinta-200 bg-white shadow-lg"
           onClick={(e) => e.stopPropagation()} role="dialog" aria-modal aria-label={titulo}>
        <header className="border-b border-tinta-200 px-4 py-3">
          <h2 className="text-sm font-semibold text-tinta-900">{titulo}</h2>
          {descripcion && <p className="mt-0.5 text-2xs text-tinta-500">{descripcion}</p>}
        </header>
        <div className="px-4 py-4">{children}</div>
        {pie && <footer className="flex justify-end gap-2 border-t border-tinta-200 px-4 py-3">{pie}</footer>}
      </div>
    </div>
  )
}

export function Cargando({ etiqueta = 'Cargando' }: { etiqueta?: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-2xs text-tinta-500">
      <Loader2 className="h-3 w-3 animate-spin" /> {etiqueta}
    </span>
  )
}
