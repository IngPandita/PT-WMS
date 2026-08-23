import { expect, test } from '@playwright/test'
import { apiContexto, filaPorClave, ir, movimientosDeProducto, usarOperador } from './ayudas'
import type { APIRequestContext } from '@playwright/test'

/**
 * E3 · El escenario del requerimiento, en un navegador de verdad: modal,
 * conexión lenta, y el usuario que vuelve a pulsar porque no ve respuesta.
 *
 * Las dos mitades de la defensa, probadas por separado:
 *
 *   · El modal de ajuste captura una cantidad OBJETIVO y deshabilita el botón
 *     mientras la petición está en vuelo. Eso es UX, y aquí se comprueba.
 *   · La garantía real es que reaplicar la misma intención no vuelve a mover
 *     nada: el objetivo es absoluto y el `id_operacion` se acuña al ABRIR el
 *     modal. Eso también se comprueba, contra la bitácora.
 *
 * Lo que NO se hace es forzar clics sobre un botón deshabilitado: un clic
 * forzado puede caer en el fondo del modal y cerrarlo, y entonces la prueba
 * mediría el arnés. El reenvío con la petición en vuelo está cubierto sobre
 * HTTP en `tests/verificar_api.sh`, que es donde se puede provocar sin
 * ambigüedad.
 */

/** El primer renglón del tablero, identificado sin ambigüedad. */
async function primerRenglon(api: APIRequestContext) {
  const r = await api.get('/api/inventario?porPagina=1')
  const { elementos } = await r.json()
  return elementos[0] as {
    productoId: number; almacenId: number; productoSku: string; cantidadFisica: number
  }
}

test('E3 · el modal bloquea el segundo disparo y el objetivo es absoluto', async ({ page }) => {
  const api = await apiContexto()

  // 5 segundos de latencia SOLO en el ajuste. Frenar todo mediría el arnés.
  await page.route('**/api/inventario/establecer', async (ruta) => {
    await new Promise((r) => setTimeout(r, 5_000))
    await ruta.continue()
  })

  const clave = await primerRenglon(api)
  const antes = await filaPorClave(api, clave.productoId, clave.almacenId)
  const objetivo = antes.cantidadFisica + 2
  const movimientosAntes = (await movimientosDeProducto(api, clave.productoId)).length

  await page.goto('/')
  await usarOperador(page, 'Bruno')
  await ir(page, 'Inventario')

  const fila = page.locator('table tbody tr').first()
  await expect(fila.locator('td').first()).toHaveText(antes.productoSku)

  await fila.getByRole('button', { name: 'Ajustar' }).click()
  const modal = page.getByRole('dialog')
  await modal.getByLabel('Existencia contada').fill(String(objetivo))
  await modal.getByLabel('Motivo').fill('Conteo físico E2E')

  // El nombre accesible cambia a «Aplicando…» en cuanto se dispara, así que
  // el localizador tiene que aceptar los dos textos o dejaría de encontrarlo.
  const aplicar = modal.getByRole('button', { name: /aplicar ajuste|aplicando/i })
  await aplicar.click()

  // Primera línea de defensa, y sólo la primera: mientras hay una petición en
  // vuelo el botón no admite un segundo disparo.
  await expect(aplicar).toBeDisabled()
  await expect(aplicar).toContainText('Aplicando')

  await expect(page.getByRole('status').last())
    .toContainText(new RegExp(`quedó en ${objetivo}`), { timeout: 40_000 })

  const despues = await filaPorClave(api, clave.productoId, clave.almacenId)
  expect(despues.cantidadFisica).toBe(objetivo)

  const movimientosDespues = await movimientosDeProducto(api, clave.productoId)
  expect(movimientosDespues.length,
    'un solo renglón de bitácora por el ajuste').toBe(movimientosAntes + 1)

  // ---------------------------------------------------------------
  // Reabrir y pedir el MISMO objetivo no es un segundo ajuste: no hay nada
  // que mover, y la interfaz no deja dispararlo.
  // ---------------------------------------------------------------
  await page.reload()
  const mismaFila = page.locator('table tbody tr').first()
  await expect(mismaFila.locator('td').first()).toHaveText(antes.productoSku)

  await mismaFila.getByRole('button', { name: 'Ajustar' }).click()
  const modal2 = page.getByRole('dialog')
  await expect(modal2.getByLabel('Existencia contada')).toHaveValue(String(objetivo))
  await expect(modal2.getByRole('button', { name: /aplicar ajuste/i })).toBeDisabled()

  const final = await filaPorClave(api, clave.productoId, clave.almacenId)
  expect(final.cantidadFisica, 'nada se movió por reabrir el modal').toBe(objetivo)
  expect((await movimientosDeProducto(api, clave.productoId)).length)
    .toBe(movimientosAntes + 1)

  await api.dispose()
})

/**
 * El stepper es el otro camino, y su regla es la contraria: NUNCA se
 * deshabilita, porque deshabilitarlo impediría justo el segundo clic que hay
 * que soportar. Acumula la intención y la manda una vez: tres clics suman
 * tres, ni uno ni nueve.
 */
test('E3b · tres clics rápidos en el stepper suman tres', async ({ page }) => {
  const api = await apiContexto()
  const clave = await primerRenglon(api)
  const antes = await filaPorClave(api, clave.productoId, clave.almacenId)

  await page.goto('/')
  await usarOperador(page, 'Bruno')
  await ir(page, 'Inventario')

  const fila = page.locator('table tbody tr').first()
  await expect(fila.locator('td').first()).toHaveText(antes.productoSku)

  const mas = fila.getByRole('button', { name: 'Sumar una unidad' })
  await mas.click()
  await mas.click()
  await mas.click()

  await expect.poll(
    async () => (await filaPorClave(api, clave.productoId, clave.almacenId)).cantidadFisica,
    { timeout: 25_000 }).toBe(antes.cantidadFisica + 3)

  await api.dispose()
})
