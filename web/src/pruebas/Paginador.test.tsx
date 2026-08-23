import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { POR_PAGINA, Paginador, usarPaginaConFiltros, type Paginado } from '../componentes/Paginador'

/** Arma la envoltura tal y como la devuelve la API. */
function paginado(total: number, numeroPagina: number): Paginado<never> {
  const totalPaginas = Math.ceil(total / POR_PAGINA)
  return {
    elementos: [], total, numeroPagina, porPagina: POR_PAGINA, totalPaginas,
    hayAnterior: numeroPagina > 1, haySiguiente: numeroPagina < totalPaginas,
  }
}

describe('Paginador', () => {
  it('el tamaño de página convenido es 25', () => {
    expect(POR_PAGINA).toBe(25)
  })

  it('muestra el rango visible y el total del conjunto filtrado', () => {
    render(<Paginador datos={paginado(137, 3)} alCambiar={() => {}} etiqueta="existencias" />)
    // Pagina 3 de 25 en 25: del 51 al 75, sobre un total de 137.
    expect(screen.getByText(/51–75 de/)).toBeInTheDocument()
    expect(screen.getByText('137')).toBeInTheDocument()
    expect(screen.getByText(/existencias/)).toBeInTheDocument()
  })

  it('señala la página actual y ofrece la primera y la última', () => {
    render(<Paginador datos={paginado(500, 10)} alCambiar={() => {}} />)
    expect(screen.getByRole('button', { current: 'page' })).toHaveTextContent('10')
    expect(screen.getByRole('button', { name: '1' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: '20' })).toBeInTheDocument()
  })

  it('avanza y retrocede de página', async () => {
    const usuario = userEvent.setup()
    const alCambiar = vi.fn()
    render(<Paginador datos={paginado(137, 3)} alCambiar={alCambiar} />)
    await usuario.click(screen.getByLabelText('Página siguiente'))
    await usuario.click(screen.getByLabelText('Página anterior'))
    expect(alCambiar.mock.calls).toEqual([[4], [2]])
  })

  it('desactiva el retroceso en la primera página y el avance en la última', () => {
    const { unmount } = render(<Paginador datos={paginado(137, 1)} alCambiar={() => {}} />)
    expect(screen.getByLabelText('Página anterior')).toBeDisabled()
    expect(screen.getByLabelText('Página siguiente')).toBeEnabled()
    unmount()

    render(<Paginador datos={paginado(137, 6)} alCambiar={() => {}} />)
    expect(screen.getByLabelText('Página anterior')).toBeEnabled()
    expect(screen.getByLabelText('Página siguiente')).toBeDisabled()
  })

  it('no se dibuja cuando el filtro no devolvió nada', () => {
    const { container } = render(<Paginador datos={paginado(0, 1)} alCambiar={() => {}} />)
    expect(container).toBeEmptyDOMElement()
  })
})

/** Pantalla mínima que combina un filtro con la paginación, como las reales. */
function Pantalla() {
  const [texto, setTexto] = useState('')
  const filtros = new URLSearchParams()
  if (texto) filtros.set('q', texto)
  const [pagina, setPagina] = usarPaginaConFiltros(filtros.toString())
  return (
    <>
      <input aria-label="filtro" value={texto} onChange={(e) => setTexto(e.target.value)} />
      <output>{pagina}</output>
      <Paginador datos={paginado(500, pagina)} alCambiar={setPagina} />
    </>
  )
}

describe('usarPaginaConFiltros', () => {
  it('regresa a la página 1 al cambiar un filtro', async () => {
    const usuario = userEvent.setup()
    render(<Pantalla />)

    await usuario.click(screen.getByRole('button', { name: '4' }))
    expect(screen.getByRole('status')).toHaveTextContent('4')

    // Cambiar el filtro estando en la 4: sin el reinicio se vería una lista
    // vacía sin explicación.
    await usuario.type(screen.getByLabelText('filtro'), 'ELEC')
    expect(screen.getByRole('status')).toHaveTextContent('1')
  })

  it('conserva la página mientras los filtros no cambian', async () => {
    const usuario = userEvent.setup()
    render(<Pantalla />)
    await usuario.click(screen.getByRole('button', { name: '3' }))
    await usuario.click(screen.getByLabelText('Página siguiente'))
    expect(screen.getByRole('status')).toHaveTextContent('4')
  })
})
