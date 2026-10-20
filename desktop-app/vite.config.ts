import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: { host: '127.0.0.1', port: 1420, strictPort: true },
  clearScreen: false,
  test: { environment: 'jsdom', include: ['src/**/*.{test,spec}.{ts,tsx}'], setupFiles: ['./src/test-setup.ts'], restoreMocks: true },
});
