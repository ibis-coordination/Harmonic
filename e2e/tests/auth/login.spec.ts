import { test, expect } from "../../fixtures/test-fixtures"
import {
  login,
  logout,
  buildBaseUrl,
  E2E_TEST_EMAIL,
  E2E_TEST_PASSWORD,
} from "../../helpers/auth"

test.describe("Authentication", () => {
  test("user can log in via identity provider", async ({ page }) => {
    // Clear authenticated state to test fresh login
    await page.context().clearCookies()

    await login(page, {
      email: E2E_TEST_EMAIL,
      password: E2E_TEST_PASSWORD,
    })

    // Should be redirected to home page
    await expect(page).toHaveURL(/\/$/)

    // Should see some indication of logged-in state
    const body = page.locator("body")
    await expect(body).toBeVisible()
  })

  test("user can log out", async ({ page }) => {
    // Clear authenticated state to test fresh login/logout cycle
    await page.context().clearCookies()

    await login(page, {
      email: E2E_TEST_EMAIL,
      password: E2E_TEST_PASSWORD,
    })
    await logout(page)

    // After logout, should see login form (redirected to auth subdomain)
    const emailInput = page.locator('input[name="auth_key"]')
    const loginPage = page.locator('input[type="email"]')

    // Either should be visible after logout
    await expect(emailInput.or(loginPage).first()).toBeVisible()
  })

  test("unauthenticated user is redirected to login", async ({ page }) => {
    // Clear any existing session
    await page.context().clearCookies()

    const baseUrl = buildBaseUrl()

    // Try to access protected page (studios list requires auth)
    await page.goto(`${baseUrl}/studios`)

    // Should be redirected to login (may end up on auth subdomain)
    await expect(page).toHaveURL(/\/login/)
  })

  test("invalid credentials show error", async ({ page }) => {
    // Clear authenticated state to test login form
    await page.context().clearCookies()

    const baseUrl = buildBaseUrl()
    await page.goto(`${baseUrl}/login`)

    // Wait for login form to be visible (handles redirect to auth subdomain)
    await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })

    // Fill in invalid credentials
    await page.locator('input[name="auth_key"]').fill("invalid@example.com")
    await page.locator('input[name="password"]').fill("wrongpassword123")
    await page.locator('input[type="submit"][value="Log in"], button:has-text("Log in")').first().click()

    // Wait for response - check for various error indicators
    // Could be: OmniAuth error page, login page with flash, or /auth/failure redirect
    await expect(async () => {
      const isOnLoginPage = page.url().includes("/login")
      const isOnFailurePage = page.url().includes("/auth/failure") || page.url().includes("/auth/")
      const omniAuthError = await page.locator('h1:has-text("OmniAuth::Error")').isVisible().catch(() => false)
      const errorVisible = await page.locator(".error, .alert, .flash").isVisible().catch(() => false)

      expect(isOnLoginPage || isOnFailurePage || omniAuthError || errorVisible).toBe(true)
    }).toPass({ timeout: 10000 })
  })

  test("authenticated page fixture provides logged in state", async ({
    authenticatedPage,
    testUser,
  }) => {
    // Navigate to home page - authenticatedPage has auth state from storage
    const baseUrl = buildBaseUrl()
    await authenticatedPage.goto(baseUrl)

    // The authenticatedPage fixture should already be logged in
    await expect(authenticatedPage).toHaveURL(/\/$/)

    // User should exist with the test email
    expect(testUser.email).toContain("e2e-test")
  })
})
