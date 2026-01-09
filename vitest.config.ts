import { defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["app/javascript/**/*.test.ts"],
    setupFiles: ["app/javascript/test/setup.ts"],
    globals: true,
  },
})
