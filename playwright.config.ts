import { defineConfig, devices } from "@playwright/test"

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "html",
  timeout: 30000,
  globalSetup: require.resolve("./e2e/global-setup"),
  use: {
    baseURL: process.env.E2E_BASE_URL || "https://app.harmonic.local",
    ignoreHTTPSErrors: true,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        // Use pre-authenticated state from global setup
        storageState: "e2e/.auth/user.json",
      },
    },
  ],
})
