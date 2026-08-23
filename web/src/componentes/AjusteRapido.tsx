import { useEffect, useRef, useState } from 'react'
import clsx from 'clsx'
import { Check, Loader2, Minus, Plus } from 'lucide-react'
import { useQueryClient } from '@tanstack/react-query'
import { usarOperacion } from '../hooks/usarOperacion'
import { usarAvisos } from './Base'
import type { ErrorApi } from '../lib/api'

interface Props {
  productoId: number
  almacenId: number
  cantidadServidor: number
  usuarioId: number
}

const RETARDO_MS = 250

/**
 * Stepper de ajuste rápido.
 *
 * Dos estados SEPARADOS a propósito:
 *   baseConfirmada — última cantidad que el servidor confirmó.
 *   deltaIntencion — lo que el usuario ha pulsado desde esa base.
 *
 * Se muestran sumados, pero jamás se mezclan: si un refetch escribiera la suma
 * sobre la base, el siguiente envío aplicaría el delta DOS veces.
 *
 * El botón NUNCA se deshabilita. Deshabilitarlo mientras hay una mutación en
 * vuelo impediría el segundo clic, que es justo el caso que hay que soportar.
 *
 * El retardo de 250 ms es OPTIMIZACIÓN DE TRÁFICO, no integridad: con o sin
 * él, tres clics acaban sumando tres. Lo que impide duplicar es el
 * `id_operacion` y el índice único del motor.
 */
export function AjusteRapido({ productoId, almacenId, cantidadServidor, usuarioId }: Props) {
  const [base, setBase] = useState(cantidadServidor)
  const [delta, setDelta] = useState(0)
  const temporizador = useRef<number | null>(null)
  const avisar = usarAvisos()
  const clienteQuery = useQueryClient()

  const alcance = `ajuste:producto=${productoId}:almacen=${almacenId}`
  const op = usarOperacion({ prefijo: 'ajuste', usuarioId, alcance })

  // El refetch actualiza SOLO la base. La intención pendiente es del usuario.
  useEffect(() => { setBase(cantidadServidor) }, [cantidadServidor])

  useEffect(() => () => { if (temporizador.current) window.clearTimeout(temporizador.current) }, [])

  const enviar = async (acumulado: number) => {
    if (acumulado === 0) return
    try {
      const r = await op.enviar<{ cantidadFisica: number; fueReenvio: boolean }>(
        '/api/inventario/ajustar',
        {
          metodo: 'POST',
          cuerpo: {
            productoId, almacenId, delta: acumulado,
            tipoMovimiento: 'AJUSTE', motivo: 'Ajuste rápido desde el tablero',
            versionEsperada: null,
          },
        },
      )
      if (!r) return                      // reemplazada por una intención más nueva
      setBase(r.cantidadFisica)
      setDelta(0)
      clienteQuery.invalidateQueries({ queryKey: ['inventario'] })
    } catch (e) {
      const err = e as ErrorApi
      avisar({
        tono: 'error',
        texto: err.titulo,
        detalle: err.esReintentable
          ? 'Puede reintentar: se reenviará la misma operación, sin riesgo de duplicar.'
          : (err.detalle ?? undefined),
      })
      // La intención se conserva para que el usuario pueda reintentarla.
      clienteQuery.invalidateQueries({ queryKey: ['inventario'] })
    }
  }

  const pulsar = (paso: number) => {
    const nuevo = delta + paso
    if (base + nuevo < 0) return
    setDelta(nuevo)
    op.marcarPendiente()
    if (temporizador.current) window.clearTimeout(temporizador.current)
    temporizador.current = window.setTimeout(() => enviar(nuevo), RETARDO_MS)
  }

  const mostrado = base + delta
  const hayPendiente = delta !== 0

  return (
    <div className="flex items-center justify-end gap-1">
      <button
        type="button" onClick={() => pulsar(-1)}
        className="boton-sutil h-6 w-6 !px-0" aria-label="Restar una unidad"
      >
        <Minus className="h-3.5 w-3.5" />
      </button>

      <span
        className={clsx(
          'w-14 text-right font-mono text-sm tabular-nums transition-colors',
          hayPendiente ? 'text-tinta-400' : 'text-tinta-900',
        )}
        title={hayPendiente ? `Pendiente de guardar: ${delta > 0 ? '+' : ''}${delta}` : undefined}
        data-testid="cantidad"
      >
        {mostrado}
      </span>

      <span className="w-4 shrink-0" aria-live="polite">
        {op.estado === 'guardando' && <Loader2 className="h-3 w-3 animate-spin text-acento-600" />}
        {op.estado === 'pendiente' && <span className="block h-1.5 w-1.5 rounded-full bg-amber-400" />}
        {op.estado === 'guardado' && !hayPendiente && <Check className="h-3 w-3 text-emerald-600" />}
      </span>

      <button
        type="button" onClick={() => pulsar(1)}
        className="boton-sutil h-6 w-6 !px-0" aria-label="Sumar una unidad"
      >
        <Plus className="h-3.5 w-3.5" />
      </button>
    </div>
  )
}
