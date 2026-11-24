import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// The dashboard only talks to the read-only API; in development requests to /api are
// proxied to uvicorn (port 8000 by default, override with EQUITYIQ_API_PORT).
const apiPort = process.env.EQUITYIQ_API_PORT ?? "8000";
export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    rollupOptions: {
      output: {
        // Libraries in their own long-cacheable chunks.
        manualChunks: { react: ["react", "react-dom", "react-router-dom"], charts: ["recharts"] },
      },
    },
  },
  server: {
    port: 5173,
    proxy: { "/api": `http://127.0.0.1:${apiPort}` },
  },
});
