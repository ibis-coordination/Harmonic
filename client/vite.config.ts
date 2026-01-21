import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"
import { tanstackRouter } from "@tanstack/router-plugin/vite"
import path from "path"

export default defineConfig({
  plugins: [
    tanstackRouter({
      routeFileIgnorePattern: ".*\\.test\\.tsx?$",
    }),
    react(),
  ],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    port: 5174,
    cors: true,
    headers: {
      "Access-Control-Allow-Origin": "*",
    },
    proxy: {
      "/api": {
        target: "https://app.harmonic.local",
        changeOrigin: true,
        secure: false,
      },
      // Proxy studio-scoped API routes (used when on /studios/{handle} pages)
      "^/studios/.*/api": {
        target: "https://app.harmonic.local",
        changeOrigin: true,
        secure: false,
      },
    },
  },
  build: {
    outDir: "../public/v2",
    emptyOutDir: true,
    manifest: true,
    rollupOptions: {
      input: path.resolve(__dirname, "index.html"),
    },
  },
})
