import { chromium, FullConfig } from "@playwright/test"
import { login } from "./helpers/auth"
import {
  E2E_TEST_EMAIL,
  E2E_TEST_PASSWORD,
} from "./helpers/auth"

const AUTH_STATE_PATH = "e2e/.auth/user.json"

/**
 * Global setup for Playwright E2E tests.
 *
 * Performs health checks and authenticates once, saving the session
 * for reuse across all tests. This dramatically speeds up test execution.
 */
async function globalSetup(config: FullConfig) {
  console.log("E2E Global Setup: Starting...")

  const baseURL =
    config.projects[0].use?.baseURL || "https://app.harmonic.local"

  // Temporarily disable SSL verification for self-signed certs
  const originalRejectUnauthorized = process.env.NODE_TLS_REJECT_UNAUTHORIZED
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

  try {
    // Check if app is running
    const healthResponse = await fetch(`${baseURL}/healthcheck`)
    if (!healthResponse.ok) {
      throw new Error(`Healthcheck failed: ${healthResponse.status}`)
    }
    console.log("E2E Global Setup: App is healthy")

    // Verify we can reach the login page
    const loginResponse = await fetch(`${baseURL}/login`, {
      redirect: "manual",
    })
    if (loginResponse.status >= 500) {
      throw new Error(`Login page error: ${loginResponse.status}`)
    }
    console.log("E2E Global Setup: Login page accessible")

    // Authenticate and save session state
    console.log("E2E Global Setup: Authenticating test user...")
    const browser = await chromium.launch()
    const context = await browser.newContext({
      ignoreHTTPSErrors: true,
    })
    const page = await context.newPage()

    await login(page, {
      email: E2E_TEST_EMAIL,
      password: E2E_TEST_PASSWORD,
      subdomain: "app",
    })

    // Save the authenticated state
    await context.storageState({ path: AUTH_STATE_PATH })
    console.log("E2E Global Setup: Authentication state saved")

    await browser.close()
  } catch (error) {
    console.error("E2E Global Setup: Failed!")
    console.error(
      "Please start the app with ./scripts/start.sh and run rake e2e:setup",
    )
    throw error
  } finally {
    // Restore original value
    if (originalRejectUnauthorized !== undefined) {
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = originalRejectUnauthorized
    } else {
      delete process.env.NODE_TLS_REJECT_UNAUTHORIZED
    }
  }

  console.log("E2E Global Setup: Complete")
}

export default globalSetup
