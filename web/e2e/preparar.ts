import { request } from '@playwright/test'

/**
 * Comprueba que la pila esté arriba ANTES de abrir un navegador.
 *
 * Sin esto, el primer `page.goto` falla con un error de red y el reporte
 * culpa a la prueba en vez de decir lo único accionable: que falta levantar
 * `docker compose up -d`.
 */
export default async function preparar() {
  const base = process.env.WMS_WEB ?? 'http://localhost:5174'
  const ctx = await request.newContext({ baseURL: base })

  try {
    const salud = await ctx.get('/api/salud', { timeout: 10_000 })
    if (!salud.ok()) throw new Error(`/api/salud respondió ${salud.status()}`)

    // La semilla tiene que estar aplicada: sin operadores ni productos, cada
    // escenario fallaría por una razón que no es la suya.
    const usuarios = await ctx.get('/api/catalogos/usuarios?porPagina=200')
    const cuerpo = await usuarios.json()
    if (!cuerpo?.elementos?.length) {
      throw new Error('La base no tiene operadores: falta aplicar la semilla.')
    }
  } catch (e) {
    throw new Error(
      `No se pudo hablar con la aplicación en ${base}.\n` +
      'Levante la pila antes de correr Playwright:\n\n' +
      '    docker compose up -d --build\n\n' +
      `Detalle: ${(e as Error).message}`)
  } finally {
    await ctx.dispose()
  }
}
