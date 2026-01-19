import { FullConfig } from "@playwright/test"

async function globalSetup(config: FullConfig) {
  console.log("E2E Global Setup: Starting...")

  const baseURL =
    config.projects[0].use?.baseURL || "https://app.harmonic.local"

  // Temporarily disable SSL verification for self-signed certs
  const originalRejectUnauthorized = process.env.NODE_TLS_REJECT_UNAUTHORIZED
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

  try {
    const response = await fetch(`${baseURL}/healthcheck`)
    if (!response.ok) {
      throw new Error(`Healthcheck failed: ${response.status}`)
    }
    console.log("E2E Global Setup: App is healthy")
  } catch (error) {
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
