import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    proxy: { '/api': { target: process.env.WMS_API ?? 'http://localhost:8080', changeOrigin: true } },
  },
  // Vitest solo mira src/: en e2e/ viven las pruebas de Playwright, que usan
  // otro corredor y fallarian aqui por no encontrar su propio contexto.
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/pruebas/preparar.ts',
    include: ['src/**/*.test.{ts,tsx}'],
  },
})
