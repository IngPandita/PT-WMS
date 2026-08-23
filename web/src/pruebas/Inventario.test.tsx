import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PaginaInventario } from '../paginas/Inventario'
import { ContextoSesion } from '../hooks/usarSesion'
import { ProveedorAvisos } from '../componentes/Base'
import type { FilaTablero, Usuario } from '../lib/tipos'

const SUPERVISOR: Usuario = { id: 3, codigo: 'SUP-01', nombre: 'Rita', rol: 'SUPERVISOR', es_activo: true }
const OPERADOR: Usuario = { id: 2, codigo: 'OP-01', nombre: 'Ana', rol: 'OPERADOR', es_activo: true }

const TOTAL = 137

let urls: string[] = []

function fila(n: number): FilaTablero {
  return {
    productoId: n, almacenId: 1, productoSku: `ELEC-${String(n).padStart(4, '0')}`,
    productoNombre: `Producto ${n}`, productoPrecio: 10, productoEstatus: 'ACTIVO',
    categoriaCodigo: 'ELEC', categoriaNombre: 'Electronica',
    almacenCodigo: 'ALM-001', almacenNombre: 'Central', localizador: 'A-01-01',
    cantidadFisica: 10, cantidadReservada: 0, cantidadDisponible: 10,
    cantidadMinima: 2, esExistenciaBaja: false,
    versionConcurrencia: 1, actualizadoEn: '2026-01-01T00:00:00Z',
  }
}

function envolver(usuario: Usuario) {
  const cliente = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={cliente}>
      <ContextoSesion.Provider value={{ usuario, usuarios: [usuario], cambiarUsuario: () => {} }}>
        <ProveedorAvisos><PaginaInventario /></ProveedorAvisos>
      </ContextoSesion.Provider>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  urls = []
  // jsdom no implementa la API de objetos-URL que usa la descarga.
  vi.stubGlobal('URL', Object.assign(URL, {
    createObjectURL: vi.fn(() => 'blob:x'), revokeObjectURL: vi.fn(),
  }))
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    urls.push(url)
    if (url.includes('/exportar')) {
      return new Response('sku,nombre\n', {
        status: 200,
        headers: { 'Content-Type': 'text/csv', 'Content-Disposition': 'attachment; filename="inv.csv"' },
      })
    }
    if (url.includes('/almacenes')) {
      return new Response(JSON.stringify({
        elementos: [{ id: 1, codigo: 'ALM-001', nombre: 'Central', es_activo: true }],
        total: 1, numeroPagina: 1, porPagina: 25, totalPaginas: 1,
        hayAnterior: false, haySiguiente: false,
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
    }
    const pagina = Number(new URL(url, 'http://x').searchParams.get('pagina') ?? 1)
    const elementos = Array.from({ length: 25 }, (_, i) => fila((pagina - 1) * 25 + i + 1))
    return new Response(JSON.stringify({
      elementos, total: TOTAL, numeroPagina: pagina, porPagina: 25, totalPaginas: 6,
      hayAnterior: pagina > 1, haySiguiente: pagina < 6,
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })
  }))
})
afterEach(() => vi.unstubAllGlobals())

const listados = () => urls.filter((u) => u.startsWith('/api/inventario?'))
const exportaciones = () => urls.filter((u) => u.includes('/exportar'))

describe('Inventario - paginacion', () => {
  it('trae 25 renglones por pagina y anuncia el total filtrado', async () => {
    envolver(SUPERVISOR)
    await screen.findByText('Producto 1')
    expect(listados()[0]).toContain('porPagina=25')
    expect(listados()[0]).toContain('pagina=1')
    expect(screen.getByText(/1–25 de/)).toBeInTheDocument()
    expect(screen.getByText(String(TOTAL))).toBeInTheDocument()
    expect(screen.queryByText('Producto 26')).not.toBeInTheDocument()
  })

  it('al filtrar estando en otra pagina, vuelve a pedir la pagina 1', async () => {
    const usuario = userEvent.setup()
    envolver(SUPERVISOR)
    await screen.findByText('Producto 1')

    await usuario.click(screen.getByRole('button', { name: '3' }))
    await screen.findByText('Producto 51')
    expect(listados().at(-1)).toContain('pagina=3')

    await usuario.type(screen.getByPlaceholderText(/Buscar por SKU/i), 'ELEC')
    await waitFor(() => expect(listados().at(-1)).toContain('q=ELEC'))
    // Sin el reinicio, la pagina 3 de un filtro con 2 paginas saldria vacia.
    expect(listados().at(-1)).toContain('pagina=1')
  })
})

describe('Inventario - exportacion', () => {
  it('exporta TODO el conjunto filtrado, no los 25 visibles', async () => {
    const usuario = userEvent.setup()
    envolver(SUPERVISOR)
    await screen.findByText('Producto 1')

    // Se filtra y ademas se avanza de pagina: la exportacion debe ignorar la
    // pagina y conservar los filtros.
    await usuario.type(screen.getByPlaceholderText(/Buscar por SKU/i), 'ELEC')
    await waitFor(() => expect(listados().at(-1)).toContain('q=ELEC'))
    await usuario.click(screen.getByRole('button', { name: 'Página siguiente' }))
    await waitFor(() => expect(listados().at(-1)).toContain('pagina=2'))

    await usuario.click(screen.getByRole('button', { name: /exportar/i }))
    await waitFor(() => expect(exportaciones()).toHaveLength(1))

    const url = exportaciones()[0]
    expect(url).toContain('q=ELEC')
    expect(url).not.toContain('pagina=')
    expect(url).not.toContain('porPagina=')
  })

  it('avisa que el archivo trae el conjunto completo y no la pagina', async () => {
    envolver(SUPERVISOR)
    await screen.findByText('Producto 1')
    expect(screen.getByText(/137 registros/)).toBeInTheDocument()
  })

  it('a un operador sin permiso ni siquiera le habilita el boton', async () => {
    envolver(OPERADOR)
    await screen.findByText('Producto 1')
    expect(screen.getByRole('button', { name: /exportar/i })).toBeDisabled()
    expect(screen.getByText(/no tiene permiso de exportación/i)).toBeInTheDocument()
  })
})
