import { Page } from "@playwright/test"

export interface LoginOptions {
  email: string
  password: string
  subdomain?: string
}

// Default test credentials (match the rake task defaults)
export const E2E_TEST_EMAIL =
  process.env.E2E_TEST_EMAIL || "e2e-test@example.com"
export const E2E_TEST_PASSWORD =
  process.env.E2E_TEST_PASSWORD || "e2e-test-password-14chars"

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
 * Signs in a user via identity provider (email/password) authentication.
 * Handles the redirect flow: tenant -> auth subdomain -> back to tenant.
 */
export async function login(page: Page, options: LoginOptions): Promise<void> {
  const { email, password, subdomain = "app" } = options
  const baseUrl = buildBaseUrl(subdomain)

  // Navigate to login page on tenant subdomain
  await page.goto(`${baseUrl}/login`)

  // Wait for login form to be visible (handles redirect to auth subdomain)
  await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })

  // Fill the identity provider form (email/password)
  // Form field names from _email_password_form.html.erb
  await page.locator('input[name="auth_key"]').fill(email)
  await page.locator('input[name="password"]').fill(password)

  // Click the Login button (handle both input and button elements)
  await page.locator('input[type="submit"][value="Log in"], button:has-text("Log in")').first().click()

  // Wait for redirect back to tenant
  await page.waitForURL(new RegExp(`${baseUrl.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`))
}

/**
 * Signs in using the default E2E test user credentials.
 * The test user must be set up via `rake e2e:setup` before running tests.
 */
export async function loginAsTestUser(
  page: Page,
  subdomain: string = "app",
): Promise<void> {
  await login(page, {
    email: E2E_TEST_EMAIL,
    password: E2E_TEST_PASSWORD,
    subdomain,
  })
}

/**
 * Logs out the current user by clearing cookies and navigating to login.
 * This bypasses any Turbo Drive interception issues.
 */
export async function logout(
  page: Page,
  subdomain: string = "app",
): Promise<void> {
  // Clear cookies to end the session
  await page.context().clearCookies()
  // Clear local and session storage as well
  await page.evaluate(() => {
    localStorage.clear()
    sessionStorage.clear()
  })
  // Navigate to login page explicitly (more reliable than reloading)
  const baseUrl = buildBaseUrl(subdomain)
  await page.goto(`${baseUrl}/login`)
  await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })
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
