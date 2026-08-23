import { expect, test } from '@playwright/test'
import type { APIRequestContext, Page } from '@playwright/test'
import { apiContexto, filaPorClave, ir, movimientosDeProducto, usarOperador } from './ayudas'

/**
 * E4 · Dos operadores, dos pestañas, el mismo producto al mismo tiempo.
 *
 * Las dos cantidades tienen que aplicarse —son intenciones distintas, no un
 * duplicado— y la bitácora debe mostrar DOS renglones, cada uno con su autor,
 * su hora y su id de operación.
 *
 * Es el contrapunto de E3: allí lo correcto era aplicar una sola vez; aquí lo
 * correcto es aplicar las dos. Una idempotencia mal planteada confunde ambos
 * casos, y esta prueba existe para separarlos.
 */

/** El primer renglón del tablero, con su clave completa. */
async function primerRenglon(api: APIRequestContext) {
  const r = await api.get('/api/inventario?porPagina=1')
  const { elementos } = await r.json()
  return elementos[0] as {
    productoId: number; almacenId: number; productoSku: string
    almacenCodigo: string; localizador: string; cantidadFisica: number
  }
}

/**
 * Deja la pestaña mostrando EXACTAMENTE un renglón: el del producto en el
 * almacén indicado. Un mismo SKU vive en varios almacenes, así que filtrar
 * por SKU no basta para saber sobre qué existencia se está pulsando.
 */
async function enfocarRenglon(page: Page, sku: string, localizador: string) {
  await page.getByPlaceholder(/buscar por sku/i).fill(sku)
  const fila = page.locator('table tbody tr').filter({ hasText: localizador }).first()
  await expect(fila).toBeVisible()
  return fila
}

test('E4 · dos operadores concurrentes: ambos deltas cuentan', async ({ browser }) => {
  const api = await apiContexto()
  const clave = await primerRenglon(api)
  const antes = await filaPorClave(api, clave.productoId, clave.almacenId)

  const ctxA = await browser.newContext()
  const ctxB = await browser.newContext()
  const pestanaA = await ctxA.newPage()
  const pestanaB = await ctxB.newPage()

  await pestanaA.goto('/')
  await pestanaB.goto('/')
  await usarOperador(pestanaA, 'Bruno')
  await usarOperador(pestanaB, 'Carla')
  await ir(pestanaA, 'Inventario')
  await ir(pestanaB, 'Inventario')

  const filaA = await enfocarRenglon(pestanaA, clave.productoSku, clave.localizador)
  const filaB = await enfocarRenglon(pestanaB, clave.productoSku, clave.localizador)

  // A suma 2, B suma 3, a la vez.
  const masA = filaA.getByRole('button', { name: 'Sumar una unidad' })
  const masB = filaB.getByRole('button', { name: 'Sumar una unidad' })
  await Promise.all([
    (async () => { await masA.click(); await masA.click() })(),
    (async () => { await masB.click(); await masB.click(); await masB.click() })(),
  ])

  await expect.poll(
    async () => (await filaPorClave(api, clave.productoId, clave.almacenId)).cantidadFisica,
    { timeout: 25_000, message: 'los dos operadores deben sumar 5 entre ambos' })
    .toBe(antes.cantidadFisica + 5)

  // Dos renglones nuevos, uno por operador, cada uno con su autor.
  const movimientos = await movimientosDeProducto(api, clave.productoId)
  const recientes = movimientos.slice(0, 2)
  const autores = recientes.map((m) => m.usuarioNombre)
  expect(new Set(autores).size, 'cada renglón lleva su propio autor').toBe(2)
  expect(autores.some((a) => a.includes('Bruno'))).toBe(true)
  expect(autores.some((a) => a.includes('Carla'))).toBe(true)

  // Y dos ids de operación distintos: son intenciones distintas.
  expect(new Set(recientes.map((m) => m.idOperacion)).size).toBe(2)

  await ctxA.close()
  await ctxB.close()
  await api.dispose()
})

/**
 * La otra mitad del mismo problema: el mismo id de operación reenviado por
 * DOS operadores distintos no debe cruzarse. El id lleva el operador como
 * prefijo justo para eso.
 */
test('E4b · el mismo id de cliente en dos operadores no colisiona', async ({ request }) => {
  const api = await apiContexto()
  const clave = await primerRenglon(api)
  const antes = (await filaPorClave(api, clave.productoId, clave.almacenId)).cantidadFisica

  const cuerpo = {
    productoId: clave.productoId, almacenId: clave.almacenId, delta: 1,
    tipoMovimiento: 'AJUSTE', motivo: 'Colisión de ids E2E', versionEsperada: null,
  }
  // El id es el MISMO para los dos; lo que los separa es el prefijo de
  // operador que la API antepone.
  const idCliente = `e2e-mismo-id-${Date.now()}`

  for (const usuario of ['3', '4']) {
    const r = await request.post('/api/inventario/ajustar', {
      headers: {
        'Content-Type': 'application/json',
        'X-Operation-Id': idCliente,
        'X-Usuario-Id': usuario,
        'X-Scope': 'ajuste:e2e',
      },
      data: cuerpo,
    })
    expect(r.status(), `el operador ${usuario} debe poder aplicar el suyo`).toBe(200)
  }

  const despues = await filaPorClave(api, clave.productoId, clave.almacenId)
  expect(despues.cantidadFisica,
    'dos operadores con el mismo id de cliente suman los dos').toBe(antes + 2)

  await api.dispose()
})
