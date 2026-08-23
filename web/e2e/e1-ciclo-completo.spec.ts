import { expect, test } from '@playwright/test'
import { apiContexto, elegirPorTexto, inventario, ir, sufijo, usarOperador } from './ayudas'

/**
 * E1 · El ciclo completo, de punta a punta y por la interfaz.
 *
 *   catálogo → producto con existencia → orden → confirmar → enviar →
 *   bitácora → tablero
 *
 * Cada paso se comprueba contra el dato guardado, no contra el texto de la
 * pantalla: lo que importa es que confirmar RESERVE sin tocar lo físico y que
 * enviar DESCUENTE, no que la interfaz lo diga.
 */
const { categoria: CATEGORIA, almacen: ALMACEN, marca: MARCA } = sufijo()
const PRODUCTO = `Producto E2E ${MARCA}`
const SKU = `${CATEGORIA}-0001`

test('E1 · catálogo, producto, orden, confirmar, enviar, bitácora y tablero', async ({ page }) => {
  const api = await apiContexto()
  await page.goto('/')

  // ---------------------------------------------------------------
  // 1. Alta de catálogos — sólo el operador SISTEMA puede
  // ---------------------------------------------------------------
  await usarOperador(page, 'Sistema')
  await ir(page, 'Catálogos')

  await page.getByRole('button', { name: 'Categorías', exact: true }).click()
  await page.getByRole('button', { name: 'Nuevo' }).click()
  await page.getByLabel('Código').fill(CATEGORIA)
  await page.getByLabel('Nombre').fill(`Categoría de prueba ${MARCA}`)
  await page.getByRole('button', { name: 'Crear', exact: true }).click()
  await expect(page.getByRole('status').last()).toContainText(/Registro creado/i)

  await page.getByRole('button', { name: 'Almacenes', exact: true }).click()
  await page.getByRole('button', { name: 'Nuevo' }).click()
  await page.getByLabel('Código').fill(ALMACEN)
  await page.getByLabel('Nombre').fill(`Bodega de prueba ${MARCA}`)
  await page.getByRole('button', { name: 'Crear', exact: true }).click()
  await expect(page.getByRole('status').last()).toContainText(/Registro creado/i)

  // ---------------------------------------------------------------
  // 2. El producto llega con existencia por la importación masiva.
  //    Un producto recién dado de alta todavía no tiene renglón de
  //    inventario: la existencia nace de un MOVIMIENTO, nunca de un alta.
  // ---------------------------------------------------------------
  await ir(page, 'Importación')
  const csv = [
    'categoria_codigo,nombre_producto,descripcion,precio_unitario,estatus,almacen_codigo,cantidad_inicial,cantidad_minima',
    `${CATEGORIA},${PRODUCTO},Alta desde la interfaz,150.00,ACTIVO,${ALMACEN},40,5`,
  ].join('\n')

  await page.locator('input[type="file"]').setInputFiles({
    name: `alta-${MARCA}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf8'),
  })
  await page.getByRole('button', { name: 'Importar' }).click()
  await expect(page.getByRole('status').last()).toContainText(/1 aplicados/, { timeout: 40_000 })

  const alta = await inventario(api, SKU)
  expect(alta.cantidadFisica).toBe(40)
  expect(alta.cantidadDisponible).toBe(40)
  expect(alta.almacenCodigo).toBe(ALMACEN)

  // ---------------------------------------------------------------
  // 3. El tablero de inventario lo muestra
  // ---------------------------------------------------------------
  await ir(page, 'Inventario')
  await page.getByPlaceholder(/buscar por sku/i).fill(SKU)
  // exact: el localizador de la misma fila es «SKU@ALMACEN» y tambien contiene el SKU.
  await expect(page.getByRole('cell', { name: SKU, exact: true })).toBeVisible()

  // ---------------------------------------------------------------
  // 4. Orden: la crea un operador cualquiera, no hace falta el SISTEMA
  // ---------------------------------------------------------------
  await usarOperador(page, 'Bruno')
  await ir(page, 'Órdenes')
  await page.getByRole('button', { name: /nueva orden/i }).click()

  const modal = page.getByRole('dialog')
  await modal.locator('select').nth(0).selectOption({ index: 1 })          // Cliente
  await elegirPorTexto(modal.locator('select').nth(1), ALMACEN)

  await modal.getByPlaceholder(/buscar por sku/i).fill(SKU)
  // Los <option> de un <select> tambien tienen rol 'option': hay que acotar
  // la busqueda al listbox del buscador o se selecciona «Seleccione…».
  await modal.getByRole('listbox').getByRole('option').first().click()
  await modal.locator('input[type="number"]').first().fill('6')

  await modal.getByRole('button', { name: /crear orden/i }).click()
  await expect(page.getByRole('status').last()).toContainText(/Orden .* creada/i)

  const folio = (await page.getByRole('status').last().innerText()).match(/ORD-\d+/)?.[0]
  expect(folio, 'la orden debe traer folio').toBeTruthy()
  const renglon = page.getByRole('row').filter({ hasText: folio! })

  // ---------------------------------------------------------------
  // 5. Confirmar RESERVA sin tocar la existencia física
  // ---------------------------------------------------------------
  await renglon.getByRole('button', { name: 'Confirmar' }).click()
  await expect(page.getByRole('status').last()).toContainText(/confirmada/i)

  const confirmada = await inventario(api, SKU)
  expect(confirmada.cantidadFisica, 'confirmar no toca lo físico').toBe(40)
  expect(confirmada.cantidadReservada).toBe(6)
  expect(confirmada.cantidadDisponible, 'lo disponible sí baja').toBe(34)

  // ---------------------------------------------------------------
  // 6. Enviar DESCUENTA lo físico y libera la reserva
  // ---------------------------------------------------------------
  await renglon.getByRole('button', { name: 'Enviar' }).click()
  await expect(page.getByRole('status').last()).toContainText(/enviada/i)

  const enviada = await inventario(api, SKU)
  expect(enviada.cantidadFisica).toBe(34)
  expect(enviada.cantidadReservada).toBe(0)
  expect(enviada.cantidadDisponible).toBe(34)

  // ---------------------------------------------------------------
  // 7. La bitácora conserva cada paso con su autor
  // ---------------------------------------------------------------
  await ir(page, 'Movimientos')
  await page.getByPlaceholder('SKU o nombre…').fill(SKU)
  await page.getByRole('listbox').getByRole('option').first().click()
  await expect(page.locator('table tbody tr').first()).toBeVisible()

  const tipos = (await page.locator('table tbody tr td:nth-child(2)').allInnerTexts()).join(' ')
  expect(tipos).toContain('importacion')
  expect(tipos).toContain('reserva')
  expect(tipos).toContain('embarque')

  // Ninguna fila queda sin autor: la trazabilidad es el punto de la bitácora.
  const autores = await page.locator('table tbody tr td:nth-child(7)').allInnerTexts()
  expect(autores.length).toBeGreaterThanOrEqual(3)
  expect(autores.every((a) => a.trim().length > 0)).toBe(true)

  // ---------------------------------------------------------------
  // 8. El tablero sigue respondiendo con los indicadores
  // ---------------------------------------------------------------
  await ir(page, 'Tablero')
  await expect(page.getByText('Unidades en existencia')).toBeVisible()
  await expect(page.getByText('Órdenes en borrador')).toBeVisible()

  await api.dispose()
})
