import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PaginaCatalogos } from '../paginas/Catalogos'
import { ContextoSesion } from '../hooks/usarSesion'
import { ProveedorAvisos } from '../componentes/Base'
import type { Usuario } from '../lib/tipos'

const SISTEMA: Usuario = { id: 1, codigo: 'SYS', nombre: 'Sistema', rol: 'SISTEMA', es_activo: true }
const OPERADOR: Usuario = { id: 2, codigo: 'OP-01', nombre: 'Ana', rol: 'OPERADOR', es_activo: true }

interface Peticion { url: string; metodo: string; usuarioId: string | null; cuerpo: string | null }

let peticiones: Peticion[] = []
/** Respuesta del POST de alta; por omision, exito. */
let respuestaAlta: () => Response = () => new Response('{}', { status: 201 })
/** Respuesta del PUT de correccion; por omision, exito. */
let respuestaEdicion: () => Response = () => new Response('{}', { status: 200 })
/** Fila 1 del listado; las pruebas la ajustan para probar vigencias. */
let fila1: Record<string, unknown> = {}

function envolver(usuario: Usuario) {
  const cliente = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={cliente}>
      <ContextoSesion.Provider value={{ usuario, usuarios: [SISTEMA, OPERADOR], cambiarUsuario: () => {} }}>
        <ProveedorAvisos><PaginaCatalogos /></ProveedorAvisos>
      </ContextoSesion.Provider>
    </QueryClientProvider>,
  )
}

function listado(pagina: number) {
  const elementos = Array.from({ length: 25 }, (_, i) => {
    const id = (pagina - 1) * 25 + i + 1
    const base: Record<string, unknown> = {
      id,
      codigo: 'COD-' + id,
      nombre: 'Registro ' + id,
      es_activo: true,
      version_concurrencia: 3,
    }
    return id === 1 ? { ...base, ...fila1 } : base
  })
  return new Response(JSON.stringify({
    elementos, total: 137, numeroPagina: pagina, porPagina: 25, totalPaginas: 6,
    hayAnterior: pagina > 1, haySiguiente: pagina < 6,
  }), { status: 200, headers: { 'Content-Type': 'application/json' } })
}

beforeEach(() => {
  peticiones = []
  fila1 = {}
  respuestaAlta = () => new Response('{}', { status: 201 })
  respuestaEdicion = () => new Response('{}', { status: 200 })
  vi.stubGlobal('fetch', vi.fn(async (url: string, init: RequestInit = {}) => {
    const metodo = init.method ?? 'GET'
    const encabezados = (init.headers ?? {}) as Record<string, string>
    peticiones.push({
      url, metodo,
      usuarioId: encabezados['X-Usuario-Id'] ?? null,
      cuerpo: typeof init.body === 'string' ? init.body : null,
    })
    if (metodo === 'PUT') return respuestaEdicion()
    if (metodo === 'POST') return respuestaAlta()
    return listado(Number(new URL(url, 'http://x').searchParams.get('pagina') ?? 1))
  }))
})
afterEach(() => vi.unstubAllGlobals())

const ultima = (metodo: string) => peticiones.filter((p) => p.metodo === metodo).at(-1)

describe('Catalogos - el alta esta reservada al operador SISTEMA', () => {
  it('no ofrece el boton Nuevo a un operador que no es SISTEMA', async () => {
    envolver(OPERADOR)
    await screen.findByText('Registro 1')
    expect(screen.queryByRole('button', { name: /nuevo/i })).not.toBeInTheDocument()
    expect(screen.getByText(/reservada al operador SISTEMA/i)).toBeInTheDocument()
  })

  it('ofrece el boton Nuevo al operador SISTEMA y envia su identidad', async () => {
    const usuario = userEvent.setup()
    envolver(SISTEMA)
    await screen.findByText('Registro 1')

    await usuario.click(screen.getByRole('button', { name: /nuevo/i }))
    await usuario.type(screen.getByLabelText(/codigo|código/i), 'elec')
    await usuario.type(screen.getByLabelText(/^nombre/i), 'Electronica')
    // El motor exige el codigo en mayusculas; el campo lo normaliza al escribir.
    expect(screen.getByLabelText(/codigo|código/i)).toHaveValue('ELEC')

    await usuario.click(screen.getByRole('button', { name: /^crear$/i }))
    await waitFor(() => expect(ultima('POST')).toBeDefined())

    expect(ultima('POST')!.url).toContain('/api/catalogos/categorias')
    expect(ultima('POST')!.usuarioId).toBe('1')
  })

  it('ocultar el boton es cortesia: si la API rechaza, se explica el motivo', async () => {
    const usuario = userEvent.setup()
    // Se simula la barrera REAL —la del backend— entrando en juego. El
    // frontend no es la restriccion, solo la refleja.
    respuestaAlta = () => new Response(JSON.stringify({
      title: 'Alta no permitida', codigoWms: 'WM020',
      detail: 'Solo el usuario SISTEMA puede dar de alta registros en catalogos.',
    }), { status: 403, headers: { 'Content-Type': 'application/json' } })

    envolver(SISTEMA)
    await screen.findByText('Registro 1')
    await usuario.click(screen.getByRole('button', { name: /nuevo/i }))
    await usuario.type(screen.getByLabelText(/codigo|código/i), 'ELEC')
    await usuario.type(screen.getByLabelText(/^nombre/i), 'Electronica')
    await usuario.click(screen.getByRole('button', { name: /^crear$/i }))

    expect(await screen.findByText(/Alta no permitida/i)).toBeInTheDocument()
  })

  it('reenviar el alta conserva el mismo id de operacion: es un reintento', async () => {
    const usuario = userEvent.setup()
    const ids: string[] = []
    vi.stubGlobal('fetch', vi.fn(async (_url: string, init: RequestInit = {}) => {
      const h = (init.headers ?? {}) as Record<string, string>
      if ((init.method ?? 'GET') === 'POST') {
        ids.push(h['X-Operation-Id'])
        return new Response(JSON.stringify({ title: 'Sin conexion' }), { status: 503 })
      }
      return listado(1)
    }))

    envolver(SISTEMA)
    await usuario.click(await screen.findByRole('button', { name: /nuevo/i }))
    await usuario.type(screen.getByLabelText(/codigo|código/i), 'ELEC')
    await usuario.type(screen.getByLabelText(/^nombre/i), 'Electronica')
    await usuario.click(screen.getByRole('button', { name: /^crear$/i }))
    await waitFor(() => expect(ids).toHaveLength(1))
    await usuario.click(screen.getByRole('button', { name: /^crear$/i }))
    await waitFor(() => expect(ids).toHaveLength(2))

    expect(ids[0]).toBe(ids[1])
    expect(ids[0]).toMatch(/^altacat-/)
  })
})

describe('Catalogos - corregir un registro', () => {
  it('corregir NO exige ser el operador SISTEMA', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await screen.findByText('Registro 1')

    // Sin seleccion no hay nada que corregir.
    expect(screen.getByRole('button', { name: /corregir/i })).toBeDisabled()

    await usuario.click(screen.getByText('Registro 1'))
    expect(screen.getByRole('button', { name: /corregir/i })).toBeEnabled()
  })

  it('precarga los valores del registro y manda solo lo que cambio', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await usuario.click(await screen.findByText('Registro 1'))
    await usuario.click(screen.getByRole('button', { name: /corregir/i }))

    const nombre = screen.getByLabelText(/^nombre/i)
    expect(nombre).toHaveValue('Registro 1')
    expect(screen.getByLabelText(/codigo|código/i)).toHaveValue('COD-1')

    await usuario.clear(nombre)
    await usuario.type(nombre, 'Registro Corregido')
    await usuario.click(screen.getByRole('button', { name: /^guardar$/i }))
    await waitFor(() => expect(ultima('PUT')).toBeDefined())

    const envio = ultima('PUT')!
    expect(envio.url).toBe('/api/catalogos/categorias/1')
    expect(envio.usuarioId).toBe('2')
    const cuerpo = JSON.parse(envio.cuerpo!)
    // Solo el nombre viaja: mandar el codigo sin tocarlo lo convertiria en un
    // cambio, y el motor lo congela en cuanto hay un SKU acunado.
    expect(Object.keys(cuerpo.campos)).toEqual(['nombre'])
    expect(cuerpo.campos.nombre).toBe('Registro Corregido')
    expect(cuerpo.versionEsperada).toBe(3)
  })

  it('sin cambios el boton de guardar no se habilita', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await usuario.click(await screen.findByText('Registro 1'))
    await usuario.click(screen.getByRole('button', { name: /corregir/i }))
    expect(screen.getByRole('button', { name: /^guardar$/i })).toBeDisabled()
  })

  it('un conflicto de version se explica en vez de pisarse', async () => {
    const usuario = userEvent.setup()
    respuestaEdicion = () => new Response(JSON.stringify({
      title: 'Alguien más modificó este registro', codigoWms: 'WM008',
      detail: 'Se esperaba la versión 3 y la actual es 4.',
    }), { status: 409, headers: { 'Content-Type': 'application/json' } })

    envolver(OPERADOR)
    await usuario.click(await screen.findByText('Registro 1'))
    await usuario.click(screen.getByRole('button', { name: /corregir/i }))
    const nombre = screen.getByLabelText(/^nombre/i)
    await usuario.clear(nombre)
    await usuario.type(nombre, 'Otro nombre')
    await usuario.click(screen.getByRole('button', { name: /^guardar$/i }))

    expect(await screen.findByText(/Alguien más modificó/i)).toBeInTheDocument()
  })

  it('el campo rol se bloquea para quien no es SISTEMA', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await usuario.click(screen.getByRole('button', { name: 'Operadores' }))
    await usuario.click(await screen.findByText('Registro 1'))
    await usuario.click(screen.getByRole('button', { name: /corregir/i }))

    expect(screen.getByLabelText(/^rol/i)).toBeDisabled()
    expect(screen.getByLabelText(/^nombre/i)).toBeEnabled()
  })

  it('el operador SISTEMA si puede tocar el rol', async () => {
    const usuario = userEvent.setup()
    envolver(SISTEMA)
    await usuario.click(screen.getByRole('button', { name: 'Operadores' }))
    await usuario.click(await screen.findByText('Registro 1'))
    await usuario.click(screen.getByRole('button', { name: /corregir/i }))

    expect(screen.getByLabelText(/^rol/i)).toBeEnabled()
  })
})

describe('Catalogos - baja logica y reactivacion', () => {
  it('ofrece dar de baja un registro vigente', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await usuario.click(await screen.findByText('Registro 1'))

    await usuario.click(screen.getByRole('button', { name: /dar de baja/i }))
    await usuario.click(screen.getAllByRole('button', { name: /dar de baja/i }).at(-1)!)
    await waitFor(() => expect(ultima('POST')).toBeDefined())

    expect(ultima('POST')!.url).toBe('/api/catalogos/categorias/1/desactivar')
    expect(ultima('POST')!.usuarioId).toBe('2')
  })

  it('a un registro ya dado de baja le ofrece reactivar', async () => {
    const usuario = userEvent.setup()
    fila1 = { es_activo: false }
    envolver(OPERADOR)
    await usuario.click(await screen.findByText('Registro 1'))

    expect(screen.queryByRole('button', { name: /dar de baja/i })).not.toBeInTheDocument()
    await usuario.click(screen.getByRole('button', { name: /reactivar/i }))
    await usuario.click(screen.getAllByRole('button', { name: /reactivar/i }).at(-1)!)
    await waitFor(() => expect(ultima('POST')).toBeDefined())

    expect(ultima('POST')!.url).toBe('/api/catalogos/categorias/1/reactivar')
  })

  it('un producto se juzga por estatus, no por es_activo', async () => {
    const usuario = userEvent.setup()
    // Productos usa `estatus` con tres valores; la fila no trae es_activo.
    fila1 = { es_activo: undefined, estatus: 'INACTIVO' }
    envolver(OPERADOR)
    await usuario.click(screen.getByRole('button', { name: 'Productos' }))
    await usuario.click(await screen.findByText('Registro 1'))

    expect(screen.getByRole('button', { name: /reactivar/i })).toBeInTheDocument()
  })

  it('explica por que el operador SISTEMA no se puede dar de baja', async () => {
    const usuario = userEvent.setup()
    respuestaAlta = () => new Response(JSON.stringify({
      title: 'El operador SISTEMA no se puede desactivar', codigoWms: 'WM022',
    }), { status: 409, headers: { 'Content-Type': 'application/json' } })

    envolver(SISTEMA)
    await usuario.click(screen.getByRole('button', { name: 'Operadores' }))
    await usuario.click(await screen.findByText('Registro 1'))
    await usuario.click(screen.getByRole('button', { name: /dar de baja/i }))
    await usuario.click(screen.getAllByRole('button', { name: /dar de baja/i }).at(-1)!)

    expect(await screen.findByText(/sin nadie que pueda hacerlo/i)).toBeInTheDocument()
  })

  it('la seleccion no sobrevive al cambio de catalogo', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await usuario.click(await screen.findByText('Registro 1'))
    expect(screen.getByRole('button', { name: /corregir/i })).toBeEnabled()

    await usuario.click(screen.getByRole('button', { name: 'Almacenes' }))
    expect(screen.getByRole('button', { name: /corregir/i })).toBeDisabled()
  })
})

describe('Catalogos - paginacion', () => {
  it('pide 25 registros por pagina y muestra el total del catalogo', async () => {
    envolver(OPERADOR)
    await screen.findByText('Registro 1')
    expect(peticiones[0].url).toContain('porPagina=25')
    expect(peticiones[0].url).toContain('pagina=1')
    expect(screen.getByText(/1–25 de/)).toBeInTheDocument()
    expect(screen.getByText('137')).toBeInTheDocument()
  })

  it('cambiar de pagina pide el siguiente bloque al backend', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await screen.findByText('Registro 1')

    await usuario.click(screen.getByLabelText('Página siguiente'))
    await screen.findByText('Registro 26')
    expect(peticiones.at(-1)!.url).toContain('pagina=2')
    expect(screen.getByText(/26–50 de/)).toBeInTheDocument()
  })

  it('cambiar de catalogo estando en otra pagina regresa a la primera', async () => {
    const usuario = userEvent.setup()
    envolver(OPERADOR)
    await screen.findByText('Registro 1')

    await usuario.click(screen.getByRole('button', { name: '4' }))
    await screen.findByText('Registro 76')

    await usuario.click(screen.getByRole('button', { name: 'Almacenes' }))
    await waitFor(() => expect(peticiones.at(-1)!.url).toContain('/api/catalogos/almacenes'))
    expect(peticiones.at(-1)!.url).toContain('pagina=1')
  })
})
