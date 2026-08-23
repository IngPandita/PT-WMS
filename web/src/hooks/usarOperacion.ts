import { useCallback, useRef, useState } from 'react'
import { acunarIdOperacion, ErrorApi, peticion, type OpcionesPeticion } from '../lib/api'

/**
 * Los cinco estados visibles de una operación. Una cifra optimista que se
 * presenta como definitiva es una mentira de interfaz: el usuario debe poder
 * distinguir "pendiente" de "guardado".
 */
export type EstadoOperacion = 'inactivo' | 'pendiente' | 'guardando' | 'guardado' | 'fallido'

interface Opciones {
  /** Prefijo legible del id; ayuda a rastrear en la bitácora. */
  prefijo: string
  usuarioId: number
  alcance: string
}

/**
 * Encapsula la disciplina del id_operacion para una intención concreta.
 *
 * El id se acuña una vez y se REUTILIZA en cada reenvío. Solo se descarta
 * cuando la operación se aplica con éxito o cuando el llamador declara que la
 * intención cambió (`reiniciar`). Esa es la diferencia entre un reintento
 * seguro y una segunda aplicación.
 */
export function usarOperacion({ prefijo, usuarioId, alcance }: Opciones) {
  const idRef = useRef<string | null>(null)
  const abortRef = useRef<AbortController | null>(null)
  const [estado, setEstado] = useState<EstadoOperacion>('inactivo')
  const [error, setError] = useState<ErrorApi | null>(null)

  /** La intención cambió: el id anterior ya no la representa. */
  const reiniciar = useCallback(() => {
    idRef.current = null
    setEstado('inactivo')
    setError(null)
  }, [])

  const idActual = useCallback(() => {
    if (!idRef.current) idRef.current = acunarIdOperacion(prefijo)
    return idRef.current
  }, [prefijo])

  const enviar = useCallback(
    async <T,>(ruta: string, opciones: Omit<OpcionesPeticion, 'idOperacion' | 'usuarioId' | 'alcance' | 'señal'>) => {
      // Se aborta la petición anterior: es UX —dejar de esperar algo que ya no
      // interesa— y nunca una garantía. La integridad la da el id_operacion.
      abortRef.current?.abort()
      const control = new AbortController()
      abortRef.current = control

      setEstado('guardando')
      setError(null)
      try {
        const r = await peticion<T>(ruta, {
          ...opciones,
          idOperacion: idActual(),
          usuarioId,
          alcance,
          señal: control.signal,
        })
        idRef.current = null // la intención se cumplió
        setEstado('guardado')
        return r
      } catch (e) {
        if ((e as Error).name === 'AbortError') {
          // Abortada por una intención más nueva. NO se toca el id ni el
          // estado: la petición que la reemplazó manda.
          return null
        }
        const err = e as ErrorApi
        setError(err)
        setEstado('fallido')
        // El id se CONSERVA: reintentar con el mismo es seguro y es lo correcto.
        throw err
      }
    },
    [idActual, usuarioId, alcance],
  )

  return { enviar, estado, error, reiniciar, marcarPendiente: () => setEstado('pendiente') }
}
