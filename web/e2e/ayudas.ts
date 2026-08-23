import { expect, type APIRequestContext, type Locator, type Page, request } from '@playwright/test'

/** El operador SISTEMA: el único que puede dar de alta en catálogos. */
export const SISTEMA = 'Sistema'

/**
 * Lee el estado REAL por la API, no por la pantalla.
 *
 * Las aserciones de integridad —«la existencia subió 2, no 4»— tienen que
 * mirar el dato, no el DOM: un contador de pantalla puede ser optimista y
 * decir lo que el usuario quiso, no lo que quedó guardado.
 */
export async function apiContexto(): Promise<APIRequestContext> {
  return request.newContext({ baseURL: process.env.WMS_WEB ?? 'http://localhost:5174' })
}

export interface FilaInventario {
  productoId: number; almacenId: number; productoSku: string; productoNombre: string
  almacenCodigo: string; cantidadFisica: number; cantidadReservada: number
  cantidadDisponible: number
}

/**
 * Un producto vive en VARIOS almacenes, asi que el SKU por si solo no
 * identifica un renglon. Cuando la prueba mira una fila concreta tiene que
 * decir tambien en que almacen, o acabaria midiendo otra existencia.
 */
export async function inventario(
  api: APIRequestContext, sku: string, almacenCodigo?: string,
): Promise<FilaInventario> {
  const r = await api.get(`/api/inventario?q=${encodeURIComponent(sku)}&porPagina=200`)
  const { elementos } = await r.json()
  const candidatos = (elementos as FilaInventario[]).filter((f) =>
    f.productoSku === sku && (almacenCodigo === undefined || f.almacenCodigo === almacenCodigo))
  if (candidatos.length === 0)
    throw new Error(`No hay inventario para ${sku}${almacenCodigo ? ` en ${almacenCodigo}` : ''}`)
  if (candidatos.length > 1)
    throw new Error(`El SKU ${sku} esta en ${candidatos.length} almacenes: indique cual.`)
  return candidatos[0]
}

/** El renglon exacto, por identificadores: sin ambiguedad posible. */
export async function filaPorClave(
  api: APIRequestContext, productoId: number, almacenId: number,
): Promise<FilaInventario> {
  const r = await api.get('/api/inventario?porPagina=200')
  const { elementos } = await r.json()
  const fila = (elementos as FilaInventario[]).find(
    (f) => f.productoId === productoId && f.almacenId === almacenId)
  if (!fila) throw new Error(`No hay inventario para producto ${productoId} en almacen ${almacenId}`)
  return fila
}

/** Cuántos renglones de bitácora dejó una operación concreta. */
export async function movimientosDe(api: APIRequestContext, idOperacion: string): Promise<number> {
  const r = await api.get(`/api/inventario/movimientos?idOperacion=${encodeURIComponent(idOperacion)}` +
                          `&desde=2000-01-01&hasta=2100-01-01&porPagina=200`)
  const { elementos } = await r.json()
  return elementos.length
}

/** Todos los movimientos de un producto dentro de una ventana amplia. */
export async function movimientosDeProducto(api: APIRequestContext, productoId: number) {
  const r = await api.get(`/api/inventario/movimientos?productoId=${productoId}` +
                          `&desde=2000-01-01&hasta=2100-01-01&porPagina=200`)
  const { elementos } = await r.json()
  return elementos as { id: number; idOperacion: string; deltaFisica: number; usuarioNombre: string }[]
}

/**
 * Elige la opcion de un <select> por una parte de su texto.
 *
 * selectOption({ label }) exige el texto EXACTO, y las opciones de esta
 * interfaz llevan codigo y nombre juntos («USR-0003 · Bruno Ortega»). Se
 * resuelve buscando la opcion y seleccionando por su value.
 */
export async function elegirPorTexto(selector: Locator, texto: string) {
  const opcion = selector.locator('option', { hasText: texto }).first()
  const valor = await opcion.getAttribute('value')
  if (valor === null) throw new Error(`No hay ninguna opcion que contenga «${texto}»`)
  await selector.selectOption(valor)
}

/** Cambia el operador activo de la barra lateral. */
export async function usarOperador(page: Page, nombre: string) {
  const selector = page.getByLabel('Operador activo')
  await expect(selector).toBeEnabled()
  await elegirPorTexto(selector, nombre)
}

/** Navega a una sección por su enlace del menú y espera a que pinte. */
export async function ir(page: Page, seccion: string) {
  await page.getByRole('link', { name: seccion }).click()
  await expect(page.getByRole('heading', { name: seccion, level: 1 })).toBeVisible()
}

/** El primer SKU visible en el tablero de inventario. */
export async function primerSkuDelTablero(page: Page): Promise<string> {
  const celda = page.locator('table tbody tr').first().locator('td').first()
  await expect(celda).toBeVisible()
  return (await celda.innerText()).trim()
}

/**
 * Identificadores irrepetibles para una corrida.
 *
 * El código de categoría tiene que ser EXACTAMENTE cuatro letras mayúsculas
 * —es el prefijo del SKU— y el de almacén `ALM-` más tres alfanuméricos, así
 * que no basta con pegarle un número al final: los dígitos del reloj se
 * traducen a letras.
 */
export function sufijo() {
  const reloj = String(Date.now())
  const letra = (d: string) => 'ABCDEFGHIJ'[Number(d)]
  const tres = reloj.slice(-3)
  return {
    categoria: 'Q' + [...tres].map(letra).join(''),
    almacen: 'ALM-' + reloj.slice(-3),
    marca: reloj.slice(-5),
  }
}
