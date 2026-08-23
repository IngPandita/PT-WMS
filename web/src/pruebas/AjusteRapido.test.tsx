import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AjusteRapido } from '../componentes/AjusteRapido'
import { ProveedorAvisos } from '../componentes/Base'
import { acunarIdOperacion } from '../lib/api'

/** Captura de lo que el componente envía realmente por la red. */
interface Envio { idOperacion: string; delta: number; alcance: string }
let envios: Envio[] = []
let responder: (envio: Envio) => Response = (e) =>
  new Response(JSON.stringify({
    productoId: 12, almacenId: 3, cantidadFisica: 100 + e.delta,
    cantidadReservada: 0, cantidadDisponible: 100 + e.delta,
    versionConcurrencia: 2, idOperacion: e.idOperacion, fueReenvio: false,
  }), { status: 200, headers: { 'Content-Type': 'application/json' } })

function montar(cantidad = 100) {
  const cliente = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={cliente}>
      <ProveedorAvisos>
        <AjusteRapido productoId={12} almacenId={3} cantidadServidor={cantidad} usuarioId={7} />
      </ProveedorAvisos>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  envios = []
  vi.stubGlobal('fetch', vi.fn(async (_url: string, init: RequestInit) => {
    const cuerpo = JSON.parse(String(init.body))
    const cabeceras = init.headers as Record<string, string>
    const envio: Envio = {
      idOperacion: cabeceras['X-Operation-Id'],
      delta: cuerpo.delta,
      alcance: cabeceras['X-Scope'],
    }
    envios.push(envio)
    return responder(envio)
  }))
})

afterEach(() => {
  vi.unstubAllGlobals()
  responder = (e) => new Response(JSON.stringify({
    productoId: 12, almacenId: 3, cantidadFisica: 100 + e.delta,
    cantidadReservada: 0, cantidadDisponible: 100 + e.delta,
    versionConcurrencia: 2, idOperacion: e.idOperacion, fueReenvio: false,
  }), { status: 200, headers: { 'Content-Type': 'application/json' } })
})

describe('AjusteRapido', () => {
  it('el boton NUNCA se deshabilita: sin segundo clic no hay nada que reemplace al primero', async () => {
    const usuario = userEvent.setup()
    montar()
    const sumar = screen.getByLabelText('Sumar una unidad')
    await usuario.click(sumar)
    expect(sumar).toBeEnabled()
    await usuario.click(sumar)
    expect(sumar).toBeEnabled()
  })

  it('acumula la intencion y emite UNA sola peticion con el total', async () => {
    const usuario = userEvent.setup()
    montar()
    const sumar = screen.getByLabelText('Sumar una unidad')
    await usuario.click(sumar)
    await usuario.click(sumar)
    await usuario.click(sumar)

    // La cifra refleja la intencion al instante, antes de guardar.
    expect(screen.getByTestId('cantidad')).toHaveTextContent('103')

    await waitFor(() => expect(envios).toHaveLength(1), { timeout: 2000 })
    expect(envios[0].delta).toBe(3)
  })

  it('el alcance identifica el control, no la peticion', async () => {
    const usuario = userEvent.setup()
    montar()
    await usuario.click(screen.getByLabelText('Sumar una unidad'))
    await waitFor(() => expect(envios).toHaveLength(1), { timeout: 2000 })
    expect(envios[0].alcance).toBe('ajuste:producto=12:almacen=3')
  })

  it('tras un exito, la siguiente intencion acuna un id NUEVO', async () => {
    const usuario = userEvent.setup()
    montar()
    const sumar = screen.getByLabelText('Sumar una unidad')

    await usuario.click(sumar)
    await waitFor(() => expect(envios).toHaveLength(1), { timeout: 2000 })
    await usuario.click(sumar)
    await waitFor(() => expect(envios).toHaveLength(2), { timeout: 2000 })

    // Son dos intenciones distintas del usuario: deben contarse las dos.
    expect(envios[0].idOperacion).not.toBe(envios[1].idOperacion)
  })

  it('tras un fallo, el reintento CONSERVA el mismo id: reintentar es seguro', async () => {
    const usuario = userEvent.setup()
    responder = () => new Response(
      JSON.stringify({ title: 'Conflicto', codigoWms: 'WM013' }),
      { status: 409, headers: { 'Content-Type': 'application/json' } })

    montar()
    const sumar = screen.getByLabelText('Sumar una unidad')
    await usuario.click(sumar)
    await waitFor(() => expect(envios).toHaveLength(1), { timeout: 2000 })

    await usuario.click(sumar)
    await waitFor(() => expect(envios).toHaveLength(2), { timeout: 2000 })

    // Es el MISMO intento del usuario reenviado: acunar un id nuevo aqui seria
    // justo lo que produce la doble aplicacion.
    expect(envios[1].idOperacion).toBe(envios[0].idOperacion)
  })

  it('un refetch actualiza la base sin descartar la intencion pendiente', async () => {
    const usuario = userEvent.setup()
    const { rerender } = montar(100)
    await usuario.click(screen.getByLabelText('Sumar una unidad'))
    expect(screen.getByTestId('cantidad')).toHaveTextContent('101')

    // Otro operador movio el producto: llega 130 desde el servidor.
    const cliente = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    rerender(
      <QueryClientProvider client={cliente}>
        <ProveedorAvisos>
          <AjusteRapido productoId={12} almacenId={3} cantidadServidor={130} usuarioId={7} />
        </ProveedorAvisos>
      </QueryClientProvider>,
    )

    // 130 + 1: la base se actualizo, la intencion sigue viva. Si se hubieran
    // mezclado, el siguiente envio aplicaria el delta dos veces.
    await waitFor(() => expect(screen.getByTestId('cantidad')).toHaveTextContent('131'))
  })

  it('no permite dejar la existencia por debajo de cero desde la interfaz', async () => {
    const usuario = userEvent.setup()
    montar(1)
    const restar = screen.getByLabelText('Restar una unidad')
    await usuario.click(restar)
    await usuario.click(restar)
    expect(screen.getByTestId('cantidad')).toHaveTextContent('0')
  })
})

describe('acunarIdOperacion', () => {
  it('produce ids distintos', () => {
    expect(acunarIdOperacion('ajuste')).not.toBe(acunarIdOperacion('ajuste'))
  })

  it("respeta el formato que exige la API y reserva ':' para el prefijo de operador", () => {
    const id = acunarIdOperacion('ajuste')
    expect(id).toMatch(/^[A-Za-z0-9._-]{8,108}$/)
    expect(id).not.toContain(':')
  })
})
