import { resolve } from 'node:path';
import { defineConfig } from 'vite';

// Three pages, one build. Each gets its own entry so the register page never
// ships the WebGL scene and the homepage never ships the table code.
export default defineConfig({
  server: { port: 5190 },
  build: {
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, 'index.html'),
        docs: resolve(import.meta.dirname, 'docs/index.html'),
        bonds: resolve(import.meta.dirname, 'bonds/index.html'),
      },
    },
  },
});
