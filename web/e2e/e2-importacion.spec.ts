import { expect, test } from '@playwright/test'
import { apiContexto, inventario, ir, sufijo, usarOperador } from './ayudas'

/**
 * E2 · Importación masiva: plantilla, archivo con errores, resultado
 * consultable y reimportación que NO duplica.
 *
 * Lo que se prueba de verdad es que un archivo parcialmente malo aplique lo
 * bueno y explique lo malo renglón por renglón, en vez de rechazarlo entero
 * o —peor— aplicarlo a medias sin decirlo.
 */
const { categoria: CATEGORIA, almacen: ALMACEN, marca: MARCA } = sufijo()

test('E2 · plantilla, importación con errores, resultado y reimportación', async ({ page }) => {
  const api = await apiContexto()
  await page.goto('/')

  // Los catálogos que el archivo va a referenciar
  await usarOperador(page, 'Sistema')
  await ir(page, 'Catálogos')
  await page.getByRole('button', { name: 'Categorías', exact: true }).click()
  await page.getByRole('button', { name: 'Nuevo' }).click()
  await page.getByLabel('Código').fill(CATEGORIA)
  await page.getByLabel('Nombre').fill(`Importación ${MARCA}`)
  await page.getByRole('button', { name: 'Crear', exact: true }).click()
  await expect(page.getByRole('status').last()).toContainText(/Registro creado/i)

  await page.getByRole('button', { name: 'Almacenes', exact: true }).click()
  await page.getByRole('button', { name: 'Nuevo' }).click()
  await page.getByLabel('Código').fill(ALMACEN)
  await page.getByLabel('Nombre').fill(`Bodega import ${MARCA}`)
  await page.getByRole('button', { name: 'Crear', exact: true }).click()
  await expect(page.getByRole('status').last()).toContainText(/Registro creado/i)

  await ir(page, 'Importación')

  // ---------------------------------------------------------------
  // 1. La plantilla se descarga
  // ---------------------------------------------------------------
  const descarga = page.waitForEvent('download')
  await page.getByRole('link', { name: /plantilla/i }).click()
  const archivo = await descarga
  expect(archivo.suggestedFilename()).toMatch(/\.csv$/)

  // ---------------------------------------------------------------
  // 2. Un archivo con buenos y malos: se aplica lo bueno, se explica lo malo
  // ---------------------------------------------------------------
  const csv = [
    'categoria_codigo,nombre_producto,descripcion,precio_unitario,estatus,almacen_codigo,cantidad_inicial,cantidad_minima',
    `${CATEGORIA},Bueno Uno ${MARCA},"Con coma, adentro",100.50,ACTIVO,${ALMACEN},10,2`,
    `${CATEGORIA},Bueno Dos ${MARCA},,200.00,ACTIVO,${ALMACEN},5,1`,
    `ZZZZ,Categoría fantasma ${MARCA},,50.00,ACTIVO,${ALMACEN},1,0`,
    `${CATEGORIA},Almacén fantasma ${MARCA},,50.00,ACTIVO,ALM-ZZZ,1,0`,
    `${CATEGORIA},Cantidad mala ${MARCA},,50.00,ACTIVO,${ALMACEN},abc,0`,
  ].join('\n')

  await page.locator('input[type="file"]').setInputFiles({
    name: `mixto-${MARCA}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf8'),
  })
  await page.getByRole('button', { name: 'Importar' }).click()

  await expect(page.getByRole('status').last())
    .toContainText(/2 aplicados · 3 con error/, { timeout: 40_000 })

  // El detalle explica CADA renglón malo con su código, no con un texto suelto.
  await expect(page.getByText('CATEGORIA_INEXISTENTE')).toBeVisible()
  await expect(page.getByText('ALMACEN_INEXISTENTE')).toBeVisible()
  await expect(page.getByText('CANTIDAD_INVALIDA')).toBeVisible()

  // Los buenos quedaron aplicados de verdad
  const uno = await inventario(api, `${CATEGORIA}-0001`)
  expect(uno.cantidadFisica).toBe(10)
  const dos = await inventario(api, `${CATEGORIA}-0002`)
  expect(dos.cantidadFisica).toBe(5)

  // ---------------------------------------------------------------
  // 3. Reimportar el MISMO archivo no duplica nada
  // ---------------------------------------------------------------
  await page.locator('input[type="file"]').setInputFiles({
    name: `mixto-${MARCA}.csv`, mimeType: 'text/csv', buffer: Buffer.from(csv, 'utf8'),
  })
  await page.getByRole('button', { name: 'Importar' }).click()
  await expect(page.getByRole('status').last()).toContainText(/aplicados/, { timeout: 40_000 })

  const unoOtraVez = await inventario(api, `${CATEGORIA}-0001`)
  expect(unoOtraVez.cantidadFisica,
    'la existencia no se duplica al reimportar el mismo archivo').toBe(10)

  // Y el producto tampoco se creó dos veces.
  const r = await api.get(`/api/productos/buscar?q=${encodeURIComponent(`Bueno Uno ${MARCA}`)}`)
  const encontrados = await r.json()
  expect(encontrados).toHaveLength(1)

  await api.dispose()
})
