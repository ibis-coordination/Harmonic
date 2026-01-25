import { test, expect } from "../../fixtures/test-fixtures"
import { buildBaseUrl } from "../../helpers/auth"

/**
 * Tests for the non-primary tenant login flow.
 *
 * Bug description: When a user navigates to a non-primary tenant subdomain
 * (e.g., second.harmonic.local), the authentication flow should:
 * 1. Redirect to auth.harmonic.local for sign-in
 * 2. Display "Log in to second.harmonic.local" on the login page
 * 3. After authentication, redirect back to second.harmonic.local
 *
 * The bug: The login page incorrectly shows "Log in to app.harmonic.local"
 * (the primary subdomain) instead of the originating tenant subdomain, and
 * after login, redirects to app.harmonic.local instead of the original tenant.
 *
 * Root cause: The redirect_to_subdomain cookie is either not being set properly
 * or not being read correctly when transitioning between subdomains.
 */
test.describe("Non-primary tenant login flow", () => {
  // Note: This test requires a secondary tenant to exist in the database.
  // The tenant must have:
  // - A subdomain different from PRIMARY_SUBDOMAIN (e.g., "second")
  // - Identity auth provider enabled
  // - The E2E test user added as a member
  //
  // You can create this with a rake task or manually in rails console:
  //   tenant = Tenant.create!(subdomain: "second", name: "Second Tenant")
  //   user = User.find_by(email: "e2e-test@example.com")
  //   tenant.add_user!(user)
  //   tenant.create_main_superagent!(created_by: user)

  test("login page shows correct tenant subdomain after redirect from non-primary tenant", async ({
    page,
  }) => {
    // Clear any existing session to start fresh
    await page.context().clearCookies()

    // Navigate to a non-primary tenant's login page
    // This assumes a tenant with subdomain "second" exists
    const secondarySubdomain = "second"
    const secondaryBaseUrl = buildBaseUrl(secondarySubdomain)

    await page.goto(`${secondaryBaseUrl}/login`)

    // Wait for login form to be visible (handles redirect to auth subdomain)
    await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })

    // The URL should now be on the auth subdomain
    const currentUrl = page.url()
    expect(currentUrl).toContain("auth.")
    expect(currentUrl).toContain("/login")

    // The login page should display the ORIGINAL tenant subdomain (second),
    // not the primary subdomain (app)
    const loginSubtitle = page.locator(".pulse-auth-subtitle code")
    await expect(loginSubtitle).toContainText(`${secondarySubdomain}.`)

    // Verify it does NOT show the primary subdomain
    await expect(loginSubtitle).not.toContainText("app.")
  })

  test("after login, user is redirected to original non-primary tenant", async ({
    page,
    testUser,
  }) => {
    // Clear any existing session
    await page.context().clearCookies()

    // Navigate to a non-primary tenant's login page
    const secondarySubdomain = "second"
    const secondaryBaseUrl = buildBaseUrl(secondarySubdomain)

    await page.goto(`${secondaryBaseUrl}/login`)

    // Wait for login form to be visible
    await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })

    // Fill in credentials on the auth subdomain
    await page.locator('input[name="auth_key"]').fill(testUser.email)
    await page.locator('input[name="password"]').fill(testUser.password)

    // Click login
    await page
      .locator('input[type="submit"][value="Log in"], button:has-text("Log in")')
      .first()
      .click()

    // Wait for the login flow to complete - use URL-based wait instead of networkidle
    // to avoid timeout issues with long-polling or websockets
    await page.waitForURL(/harmonic\.local\/?$/, { timeout: 30000 })

    // After successful login, should be redirected to the SECONDARY tenant,
    // not the primary tenant
    const finalUrl = page.url()

    // BUG: Currently redirects to app.harmonic.local instead of second.harmonic.local
    // This assertion documents the expected behavior (will fail until bug is fixed)
    expect(finalUrl).toContain(`${secondarySubdomain}.`)
    expect(finalUrl).not.toContain("app.")
  })

  test("primary tenant login flow works correctly (baseline)", async ({ page, testUser }) => {
    // This test verifies the baseline case still works
    await page.context().clearCookies()

    const primaryBaseUrl = buildBaseUrl("app")

    await page.goto(`${primaryBaseUrl}/login`)

    // Wait for login form to be visible
    await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })

    // Should be on auth subdomain
    expect(page.url()).toContain("auth.")

    // Login page should show primary subdomain
    const loginSubtitle = page.locator(".pulse-auth-subtitle code")
    await expect(loginSubtitle).toContainText("app.")

    // Complete login
    await page.locator('input[name="auth_key"]').fill(testUser.email)
    await page.locator('input[name="password"]').fill(testUser.password)
    await page
      .locator('input[type="submit"][value="Log in"], button:has-text("Log in")')
      .first()
      .click()

    // Wait for redirect to complete - the URL should end up on app.harmonic.local
    await page.waitForURL(/app\.harmonic\.local/, { timeout: 30000 })

    // Should end up on primary tenant
    expect(page.url()).toContain("app.")
  })
})
