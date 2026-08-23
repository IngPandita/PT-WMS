import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { BuscadorProductos } from '../componentes/BuscadorProductos'
import type { ProductoEncontrado } from '../lib/tipos'

const producto = (id: number, sku: string, nombre: string): ProductoEncontrado => ({
  id, sku, nombre, categoriaNombre: 'Electronica',
  precioUnitario: 100, estatus: 'ACTIVO', cantidadDisponible: 5,
})

let consultas: string[] = []
/** Permite responder distinto —y con distinta latencia— segun el texto. */
let responder: (q: string) => Promise<ProductoEncontrado[]> = async () => []

beforeEach(() => {
  consultas = []
  vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit) => {
    const q = new URL(url, 'http://x').searchParams.get('q') ?? ''
    consultas.push(q)
    const datos = await responder(q)
    if ((init?.signal as AbortSignal)?.aborted) throw Object.assign(new Error('abort'), { name: 'AbortError' })
    return new Response(JSON.stringify(datos), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })
  }))
})
afterEach(() => { vi.unstubAllGlobals(); responder = async () => [] })

describe('BuscadorProductos', () => {
  it('no consulta con menos de dos caracteres', async () => {
    const usuario = userEvent.setup()
    render(<BuscadorProductos seleccionado={null} alSeleccionar={() => {}} />)
    await usuario.type(screen.getByRole('combobox'), 'E')
    await new Promise((r) => setTimeout(r, 500))
    expect(consultas).toHaveLength(0)
    expect(screen.getByText(/al menos dos caracteres/i)).toBeInTheDocument()
  })

  it('agrupa las pulsaciones en una sola consulta', async () => {
    const usuario = userEvent.setup()
    responder = async () => [producto(1, 'ELEC-0001', 'Cable HDMI')]
    render(<BuscadorProductos seleccionado={null} alSeleccionar={() => {}} />)

    await usuario.type(screen.getByRole('combobox'), 'ELEC')
    await waitFor(() => expect(consultas.length).toBeGreaterThan(0), { timeout: 2000 })

    // Cuatro teclas, una sola peticion: el ultimo texto es el que viaja.
    expect(consultas).toHaveLength(1)
    expect(consultas[0]).toBe('ELEC')
  })

  it('entrega el PRODUCTO con su id real, no el texto tecleado', async () => {
    const usuario = userEvent.setup()
    responder = async () => [producto(42, 'ELEC-0042', 'Teclado')]
    const alSeleccionar = vi.fn()
    render(<BuscadorProductos seleccionado={null} alSeleccionar={alSeleccionar} />)

    await usuario.type(screen.getByRole('combobox'), 'tecla')
    const opcion = await screen.findByText('Teclado', {}, { timeout: 2000 })
    await usuario.click(opcion)

    expect(alSeleccionar).toHaveBeenCalledWith(expect.objectContaining({ id: 42, sku: 'ELEC-0042' }))
  })

  it('una respuesta vieja NO pisa a una mas reciente', async () => {
    const usuario = userEvent.setup()
    // La primera busqueda tarda; la segunda vuelve enseguida. Si el componente
    // no ordenara por secuencia, la lenta sobrescribiria a la rapida al llegar.
    responder = async (q) => {
      if (q === 'lenta') {
        await new Promise((r) => setTimeout(r, 400))
        return [producto(1, 'ELEC-0001', 'Resultado viejo')]
      }
      return [producto(2, 'ELEC-0002', 'Resultado nuevo')]
    }

    render(<BuscadorProductos seleccionado={null} alSeleccionar={() => {}} />)
    const caja = screen.getByRole('combobox')

    await usuario.type(caja, 'lenta')
    await usuario.clear(caja)
    await usuario.type(caja, 'rapida')

    await screen.findByText('Resultado nuevo', {}, { timeout: 2000 })
    await new Promise((r) => setTimeout(r, 600))   // margen para que llegue la lenta

    expect(screen.queryByText('Resultado viejo')).not.toBeInTheDocument()
    expect(screen.getByText('Resultado nuevo')).toBeInTheDocument()
  })

  it('avisa cuando no hay coincidencias', async () => {
    const usuario = userEvent.setup()
    responder = async () => []
    render(<BuscadorProductos seleccionado={null} alSeleccionar={() => {}} />)
    await usuario.type(screen.getByRole('combobox'), 'zzzz')
    expect(await screen.findByText(/Ningun producto coincide|Ningún producto coincide/i, {}, { timeout: 2000 }))
      .toBeInTheDocument()
  })

  it('muestra el error y ofrece reintentar', async () => {
    const usuario = userEvent.setup()
    responder = async () => { throw new Error('boom') }
    vi.stubGlobal('fetch', vi.fn(async () =>
      new Response(JSON.stringify({ title: 'Fallo la busqueda' }),
        { status: 500, headers: { 'Content-Type': 'application/json' } })))

    render(<BuscadorProductos seleccionado={null} alSeleccionar={() => {}} />)
    await usuario.type(screen.getByRole('combobox'), 'algo')
    expect(await screen.findByText(/Reintentar/i, {}, { timeout: 2000 })).toBeInTheDocument()
  })

  it('escribir de nuevo deselecciona: el id anterior ya no representa lo tecleado', async () => {
    const usuario = userEvent.setup()
    responder = async () => [producto(7, 'ELEC-0007', 'Mouse')]
    const alSeleccionar = vi.fn()
    render(<BuscadorProductos seleccionado={producto(7, 'ELEC-0007', 'Mouse')}
                              alSeleccionar={alSeleccionar} />)
    await usuario.type(screen.getByRole('combobox'), 'x')
    expect(alSeleccionar).toHaveBeenCalledWith(null)
  })
})
