/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // Paleta sobria, estilo Linear: un solo acento y muchos grises.
        tinta:  { 50:'#f7f8f8', 100:'#eceef0', 200:'#d9dde1', 300:'#b8bfc7',
                  400:'#8f99a4', 500:'#6b7684', 600:'#525b68', 700:'#414853',
                  800:'#2b3038', 900:'#1c2025', 950:'#111316' },
        acento: { 50:'#eef2ff', 100:'#e0e7ff', 300:'#a5b4fc', 500:'#6366f1',
                  600:'#4f46e5', 700:'#4338ca' },
      },
      fontFamily: { sans: ['Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'] },
      fontSize: { '2xs': ['0.6875rem', { lineHeight: '1rem' }] },
    },
  },
  plugins: [],
}
