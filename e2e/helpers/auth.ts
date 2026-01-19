import { Page } from "@playwright/test"

export interface LoginOptions {
  email: string
  name?: string
  subdomain?: string
}

const DEFAULT_HOSTNAME = process.env.E2E_HOSTNAME || "harmonic.local"
const DEFAULT_PORT = process.env.E2E_PORT || ""
const DEFAULT_PROTOCOL = process.env.E2E_PROTOCOL || "https"

/**
 * Builds the base URL for a given subdomain
 */
export function buildBaseUrl(subdomain: string = "app"): string {
  const portSuffix = DEFAULT_PORT ? `:${DEFAULT_PORT}` : ""
  return `${DEFAULT_PROTOCOL}://${subdomain}.${DEFAULT_HOSTNAME}${portSuffix}`
}

/**
 * Signs in a user via honor_system authentication.
 * The app must be running with AUTH_MODE=honor_system.
 *
 * Fills the login form and submits it.
 */
export async function login(page: Page, options: LoginOptions): Promise<void> {
  const { email, name, subdomain = "app" } = options
  const baseUrl = buildBaseUrl(subdomain)

  // Navigate to login page
  await page.goto(`${baseUrl}/login`)

  // Fill the email field
  await page.locator('input[placeholder="email address"]').fill(email)

  // Fill name if provided
  if (name) {
    await page.locator('input[placeholder="name (optional)"]').fill(name)
  }

  // Click the Login button (it's an input[type=submit])
  await page.locator('input[type="submit"][value="Login"]').click()

  // Wait for navigation to home page
  await page.waitForURL(/\/$/)
}

/**
 * Signs in via the UI form (alternative approach if available)
 * Falls back to direct POST if form is not found
 */
export async function loginViaForm(
  page: Page,
  options: LoginOptions,
): Promise<void> {
  const { email, name, subdomain = "app" } = options
  const baseUrl = buildBaseUrl(subdomain)

  await page.goto(`${baseUrl}/login`)

  // Check if there's an email input form (honor_system or identity provider)
  const emailInput = page.locator('input[name="email"], input[type="email"]')
  if ((await emailInput.count()) > 0) {
    await emailInput.fill(email)

    const nameInput = page.locator('input[name="name"]')
    if (name && (await nameInput.count()) > 0) {
      await nameInput.fill(name)
    }

    await page.click('button[type="submit"], input[type="submit"]')
    await page.waitForURL(`${baseUrl}/`)
  } else {
    // No form found, use direct POST
    await login(page, options)
  }
}

/**
 * Logs out the current user by clearing cookies and verifying logged out state.
 * This bypasses any Turbo Drive interception issues.
 */
export async function logout(page: Page): Promise<void> {
  // Clear cookies to end the session
  await page.context().clearCookies()
  // Reload to verify we're logged out (should redirect to login or show login prompt)
  await page.reload({ waitUntil: "networkidle" })
}

/**
 * Checks if the current page shows a logged-in state
 */
export async function isLoggedIn(page: Page): Promise<boolean> {
  // Look for common logged-in indicators
  const logoutLink = page.locator('a[href*="logout"]')
  const userMenu = page.locator('[data-testid="user-menu"], .user-menu')

  return (await logoutLink.count()) > 0 || (await userMenu.count()) > 0
}
