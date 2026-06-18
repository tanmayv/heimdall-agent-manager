/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/ui/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        odin: {
          bg: '#0f172a',
          panel: '#111827',
          line: '#263244',
          accent: '#60a5fa',
          good: '#34d399',
        },
      },
    },
  },
  plugins: [],
};
