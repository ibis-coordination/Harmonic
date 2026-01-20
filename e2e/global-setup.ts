import { FullConfig } from "@playwright/test"

/**
 * Global setup for Playwright E2E tests.
 *
 * TODO: Remove honor_system requirement
 * Currently, E2E tests require AUTH_MODE=honor_system because the tests use a simple
 * email-based login flow that bypasses OAuth. This is a temporary workaround.
 *
 * The goal is to get E2E tests working with AUTH_MODE=oauth so that:
 * 1. E2E tests can run in the same environment as production
 * 2. We don't need to switch AUTH_MODE between running Ruby tests and E2E tests
 * 3. The test environment more closely matches production behavior
 *
 * To achieve this, we'll need to either:
 * - Mock the OAuth flow in tests
 * - Use Playwright's authentication state storage to persist OAuth sessions
 * - Create a test-specific authentication bypass that works in oauth mode
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

    // TEMPORARY: Check if AUTH_MODE is honor_system by examining the login page.
    // This requirement should be removed once E2E tests support oauth mode.
    // See the TODO comment at the top of this file for more details.
    // In honor_system mode, the login page has an email input field.
    // In oauth mode, the login page redirects to OAuth provider.
    const loginResponse = await fetch(`${baseURL}/login`, {
      redirect: "manual", // Don't follow redirects
    })
    const loginHtml = await loginResponse.text()

    // Honor system login page has an email input field
    const isHonorSystemMode = loginHtml.includes('name="email"')

    if (!isHonorSystemMode) {
      throw new Error(
        `❌ E2E tests require AUTH_MODE=honor_system, but the app appears to be running in oauth mode.

The E2E test suite requires honor system authentication mode. Please:
1. Stop the app: ./scripts/stop.sh
2. Set AUTH_MODE: export AUTH_MODE=honor_system
3. Restart the app: ./scripts/start.sh

Note: Ruby tests require AUTH_MODE=oauth, so you may need to switch modes.`
      )
    }
    console.log("E2E Global Setup: AUTH_MODE=honor_system confirmed")
  } catch (error) {
    if (error instanceof Error && error.message.includes("AUTH_MODE")) {
      // Re-throw auth mode errors as-is
      throw error
    }
    console.error("E2E Global Setup: App is not running!")
    console.error("Please run ./scripts/start.sh with AUTH_MODE=honor_system")
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
