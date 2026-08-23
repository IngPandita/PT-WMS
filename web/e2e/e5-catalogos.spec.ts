import { expect, test } from '@playwright/test'
import { apiContexto, ir, sufijo, usarOperador } from './ayudas'

/**
 * E5 · Permisos de catálogo desde el navegador.
 *
 * El alta está reservada al operador SISTEMA; corregir y dar de baja no. Y
 * ocultar el botón es cortesía, no seguridad: la última prueba llama al
 * endpoint directamente, saltándose la interfaz, y espera el mismo rechazo.
 */
const { categoria: CATEGORIA, marca: MARCA } = sufijo()

test('E5 · el botón Nuevo sólo aparece para el operador SISTEMA', async ({ page }) => {
  await page.goto('/')
  await ir(page, 'Catálogos')

  await usarOperador(page, 'Bruno')
  await expect(page.getByRole('button', { name: 'Nuevo' })).toHaveCount(0)
  await expect(page.getByText(/reservada al operador SISTEMA/i)).toBeVisible()

  await usarOperador(page, 'Sistema')
  await expect(page.getByRole('button', { name: 'Nuevo' })).toBeVisible()
})

test('E5b · corregir y dar de baja no exigen ser el SISTEMA', async ({ page }) => {
  const api = await apiContexto()
  await page.goto('/')

  // El registro lo crea el SISTEMA…
  await usarOperador(page, 'Sistema')
  await ir(page, 'Catálogos')
  await page.getByRole('button', { name: 'Categorías', exact: true }).click()
  await page.getByRole('button', { name: 'Nuevo' }).click()
  await page.getByLabel('Código').fill(CATEGORIA)
  await page.getByLabel('Nombre').fill(`Original ${MARCA}`)
  await page.getByRole('button', { name: 'Crear', exact: true }).click()
  await expect(page.getByRole('status').last()).toContainText(/Registro creado/i)

  // …y lo corrige un operador cualquiera.
  await usarOperador(page, 'Bruno')
  const renglon = page.getByRole('row').filter({ hasText: CATEGORIA })
  await expect(renglon).toBeVisible()
  await renglon.click()

  await page.getByRole('button', { name: /corregir/i }).click()
  const modal = page.getByRole('dialog')
  await modal.getByLabel('Nombre').fill(`Corregida ${MARCA}`)
  await modal.getByRole('button', { name: 'Guardar', exact: true }).click()
  await expect(page.getByRole('status').last()).toContainText(/Registro corregido/i)
  await expect(page.getByRole('row').filter({ hasText: `Corregida ${MARCA}` })).toBeVisible()

  // La baja es lógica: el registro sigue ahí, marcado.
  await page.getByRole('row').filter({ hasText: CATEGORIA }).click()
  await page.getByRole('button', { name: /dar de baja/i }).click()
  await page.getByRole('dialog').getByRole('button', { name: /dar de baja/i }).click()
  await expect(page.getByRole('status').last()).toContainText(/dado de baja/i)

  const r = await api.get('/api/catalogos/categorias?soloVigentes=false&porPagina=200')
  const { elementos } = await r.json()
  const guardada = elementos.find((c: { codigo: string }) => c.codigo === CATEGORIA)
  expect(guardada, 'la baja no borra el registro').toBeTruthy()
  expect(guardada.es_activo).toBe(false)
  expect(guardada.desactivado_en, 'la baja se sella con fecha').toBeTruthy()

  // Y se puede reactivar sin perder el rastro de la baja anterior.
  await page.getByRole('row').filter({ hasText: CATEGORIA }).click()
  await page.getByRole('button', { name: /reactivar/i }).click()
  await page.getByRole('dialog').getByRole('button', { name: /reactivar/i }).click()
  await expect(page.getByRole('status').last()).toContainText(/reactivado/i)

  const r2 = await api.get('/api/catalogos/categorias?soloVigentes=false&porPagina=200')
  const reactivada = (await r2.json()).elementos
    .find((c: { codigo: string }) => c.codigo === CATEGORIA)
  expect(reactivada.es_activo).toBe(true)
  expect(reactivada.desactivado_en,
    'reactivar conserva el sello de la baja anterior').toBeTruthy()

  await api.dispose()
})

test('E5c · ocultar el botón es cortesía: la API rechaza igual', async ({ request }) => {
  // Se llama al endpoint saltándose la interfaz, que es justo lo que haría
  // alguien que quisiera evitar la restricción.
  const r = await request.post('/api/catalogos/categorias', {
    headers: {
      'Content-Type': 'application/json',
      'X-Operation-Id': `e2e-bypass-${Date.now()}`,
      'X-Usuario-Id': '3',
      'X-Scope': 'catalogo:alta',
    },
    data: { codigo: 'ZZZY', nombre: 'Por la puerta de atrás' },
  })

  expect(r.status()).toBe(403)
  expect((await r.json()).codigoWms).toBe('WM020')
})

test('E5d · el rol de un operador no es una vía de ascenso', async ({ request }) => {
  const api = await apiContexto()
  const lista = await (await api.get('/api/catalogos/usuarios?porPagina=200')).json()
  const operador = lista.elementos.find((u: { rol: string }) => u.rol === 'OPERADOR')
  expect(operador, 'la semilla debe traer al menos un OPERADOR').toBeTruthy()

  const r = await request.put(`/api/catalogos/usuarios/${operador.id}`, {
    headers: {
      'Content-Type': 'application/json',
      'X-Operation-Id': `e2e-ascenso-${Date.now()}`,
      'X-Usuario-Id': String(operador.id),
      'X-Scope': 'catalogo:editar',
    },
    data: { campos: { rol: 'SUPERVISOR' }, versionEsperada: operador.version_concurrencia },
  })

  expect(r.status()).toBe(403)
  expect((await r.json()).codigoWms).toBe('WM021')

  // Y sigue sin poder exportar, que es lo que el ascenso le habría dado.
  const exportar = await request.get('/api/inventario/exportar',
    { headers: { 'X-Usuario-Id': String(operador.id) } })
  expect(exportar.status()).toBe(403)

  await api.dispose()
})
