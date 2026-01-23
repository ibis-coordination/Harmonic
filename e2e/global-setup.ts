import { FullConfig } from "@playwright/test"

/**
 * Global setup for Playwright E2E tests.
 *
 * Performs health checks to ensure the app is running before tests execute.
 * Tests use identity provider (email/password) authentication with a
 * pre-configured test user created by `rake e2e:setup`.
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
  } catch (error) {
    console.error("E2E Global Setup: App is not running!")
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
