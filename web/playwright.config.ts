import { defineConfig, devices } from '@playwright/test'

/**
 * Playwright corre contra la PILA REAL levantada con `docker compose up -d`:
 * nginx sirviendo el bundle compilado y proxyando /api a la API en .NET, que
 * a su vez habla con PostgreSQL. No hay dobles ni mocks — si el navegador ve
 * una existencia de 42, hay 42 en la tabla.
 *
 * `workers: 1` y `fullyParallel: false` no son pereza: el estado es
 * COMPARTIDO. Dos pruebas ajustando el mismo producto a la vez se pisarían
 * los conteos y el fallo diría más del arnés que del producto. Los escenarios
 * que sí necesitan concurrencia la crean dentro de la prueba, con dos
 * contextos de navegador.
 */
const BASE = process.env.WMS_WEB ?? 'http://localhost:5174'

export default defineConfig({
  testDir: './e2e',
  globalSetup: './e2e/preparar.ts',
  timeout: 90_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: BASE,
    locale: 'es-MX',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    actionTimeout: 20_000,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})
