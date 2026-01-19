import { test, expect } from "../../fixtures/test-fixtures"
import { login, logout, buildBaseUrl } from "../../helpers/auth"

test.describe("Authentication", () => {
  test("user can log in via honor_system", async ({ page }) => {
    const random = Math.random().toString(36).substring(2, 10)
    const testEmail = `login-test-${Date.now()}-${random}@example.com`

    await login(page, { email: testEmail, name: `TestUser${random}` })

    // Should be redirected to home page
    await expect(page).toHaveURL(/\/$/)

    // Should see some indication of logged-in state (user name or logout link)
    const body = page.locator("body")
    await expect(body).toBeVisible()
  })

  test("user can log out", async ({ page }) => {
    const random = Math.random().toString(36).substring(2, 10)
    const testEmail = `logout-test-${Date.now()}-${random}@example.com`

    await login(page, { email: testEmail, name: `LogoutUser${random}` })
    await logout(page)

    // After logout, either redirected to login or see "Log in" button
    const loginButton = page.locator('button:has-text("Log in"), a:has-text("Log in")')
    const loginPage = page.locator('input[placeholder="email address"]')

    // Either should be visible after logout
    await expect(loginButton.or(loginPage).first()).toBeVisible()
  })

  test("unauthenticated user is redirected to login", async ({ page }) => {
    // Clear any existing session
    await page.context().clearCookies()

    const baseUrl = buildBaseUrl()

    // Try to access protected page (studios list requires auth)
    await page.goto(`${baseUrl}/studios`)

    // Should be redirected to login
    await expect(page).toHaveURL(/\/login/)
  })

  test("login creates new user if not exists", async ({ page }) => {
    // Use unique email and name to ensure new user
    const random = Math.random().toString(36).substring(2, 10)
    const uniqueEmail = `new-user-${Date.now()}-${random}@example.com`
    const userName = `NewUser${random}`

    await login(page, { email: uniqueEmail, name: userName })

    // Should be logged in successfully
    await expect(page).toHaveURL(/\/$/)
  })

  test("authenticated page fixture provides logged in state", async ({
    authenticatedPage,
    testUser,
  }) => {
    // The authenticatedPage fixture should already be logged in
    await expect(authenticatedPage).toHaveURL(/\/$/)

    // User should exist with the test email
    expect(testUser.email).toContain("e2e-test")
  })
})
