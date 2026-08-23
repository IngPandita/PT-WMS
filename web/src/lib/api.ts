/**
 * Cliente HTTP con la disciplina del protocolo de operación.
 *
 * Las tres reglas que importan, y que el resto del frontend hereda:
 *
 *   1. El `id_operacion` se acuña UNA vez por INTENCIÓN del usuario y se
 *      reutiliza en todos los reenvíos. No es "un id por petición": eso es
 *      exactamente lo que volvería a permitir la doble aplicación.
 *   2. Cancelar con AbortController es UX y ahorro de tráfico, JAMÁS una
 *      garantía de integridad. Si la petición ya llegó y confirmó, abortarla
 *      no revierte nada.
 *   3. Un abort o un timeout NUNCA se interpretan como "no se aplicó". Ante la
 *      duda se reenvía la MISMA operación; el backend devuelve la respuesta
 *      original si ya se aplicó.
 */

export class ErrorApi extends Error {
  constructor(
    readonly estado: number,
    readonly codigoWms: string | null,
    readonly titulo: string,
    readonly detalle: string | null,
  ) {
    super(titulo)
  }

  /** ¿Reenviar la MISMA operación puede resolverlo? */
  get esReintentable() {
    return this.codigoWms === 'WM013' || this.estado === 503 || this.estado === 0
  }
}

export interface OpcionesPeticion {
  metodo?: 'GET' | 'POST' | 'PUT'
  cuerpo?: unknown
  /** Identidad de la intención. Obligatorio en toda mutación. */
  idOperacion?: string
  usuarioId?: number
  alcance?: string
  señal?: AbortSignal
  formulario?: FormData
}

const BASE = import.meta.env.VITE_API ?? ''

export async function peticion<T>(ruta: string, opciones: OpcionesPeticion = {}): Promise<T> {
  const { metodo = 'GET', cuerpo, idOperacion, usuarioId, alcance, señal, formulario } = opciones

  const encabezados: Record<string, string> = {}
  if (!formulario && cuerpo !== undefined) encabezados['Content-Type'] = 'application/json'
  if (idOperacion) encabezados['X-Operation-Id'] = idOperacion
  if (usuarioId) encabezados['X-Usuario-Id'] = String(usuarioId)
  if (alcance) encabezados['X-Scope'] = alcance

  let respuesta: Response
  try {
    respuesta = await fetch(`${BASE}${ruta}`, {
      method: metodo,
      headers: encabezados,
      body: formulario ?? (cuerpo !== undefined ? JSON.stringify(cuerpo) : undefined),
      signal: señal,
    })
  } catch (e) {
    if ((e as Error).name === 'AbortError') throw e
    // La red falló. NO se sabe si el servidor aplicó la operación; el llamador
    // debe reenviar el MISMO id, nunca acuñar uno nuevo.
    throw new ErrorApi(0, null, 'No se pudo contactar al servidor', (e as Error).message)
  }

  if (respuesta.status === 204) return undefined as T

  const texto = await respuesta.text()
  const datos = texto ? JSON.parse(texto) : null

  if (!respuesta.ok) {
    throw new ErrorApi(
      respuesta.status,
      datos?.codigoWms ?? null,
      datos?.title ?? `Error ${respuesta.status}`,
      datos?.detail ?? null,
    )
  }
  return datos as T
}

/**
 * Acuña un identificador de operación. Se llama al FORMAR la intención —abrir
 * un modal, empezar a ajustar una cantidad— y su valor se conserva hasta que
 * la operación se aplica o la intención cambia.
 */
export function acunarIdOperacion(prefijo: string): string {
  const aleatorio =
    globalThis.crypto?.randomUUID?.().replaceAll('-', '').slice(0, 16) ??
    Math.random().toString(36).slice(2, 18)
  return `${prefijo}-${aleatorio}`.replace(/[^A-Za-z0-9._-]/g, '').slice(0, 108)
}
