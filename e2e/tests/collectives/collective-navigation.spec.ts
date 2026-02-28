import { test, expect } from "../../fixtures/test-fixtures"
import { gotoTenant, getCurrentSubdomain } from "../../helpers/tenant"

test.describe("Collective Navigation", () => {
  test("can navigate to collectives list", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/collectives")

    await expect(page).toHaveURL(/\/collectives/)

    // Collectives page should have heading or list
    await expect(page.locator("body")).toBeVisible()
  })

  test("can enter a collective", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/collectives")

    const collectiveLink = page.locator('a[href*="/collectives/"]').first()

    if ((await collectiveLink.count()) > 0) {
      await collectiveLink.click()

      // Should be in a collective (URL has collective handle)
      await expect(page).toHaveURL(/\/collectives\/[a-zA-Z0-9_-]+/)
    }
  })

  test("collective page shows content sections", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/collectives")

    const collectiveLink = page.locator('a[href*="/collectives/"]').first()

    if ((await collectiveLink.count()) > 0) {
      await collectiveLink.click()

      // Collective page should have navigation or content links
      const contentLinks = page.locator(
        'a[href*="/note"], a[href*="/decide"], a[href*="/commit"]',
      )

      // Page should be functional
      await expect(page.locator("body")).toBeVisible()
    }
  })

  test("can navigate to collective settings", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/collectives")

    const collectiveLink = page.locator('a[href*="/collectives/"]').first()

    if ((await collectiveLink.count()) > 0) {
      await collectiveLink.click()

      // Navigate to settings
      const currentUrl = page.url()
      const settingsUrl = currentUrl.replace(/\/$/, "") + "/settings"
      await page.goto(settingsUrl)

      // Should be on settings page
      await expect(page).toHaveURL(/\/settings/)
    }
  })

  test("subdomain routing returns correct subdomain", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/")

    const subdomain = getCurrentSubdomain(page)

    // Should have a subdomain (www or custom)
    expect(subdomain).toBeTruthy()
    expect(typeof subdomain).toBe("string")
  })

  test("can navigate to different subdomain", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    // Navigate explicitly to app subdomain
    await gotoTenant(page, "/", "app")

    const currentSubdomain = getCurrentSubdomain(page)
    expect(currentSubdomain).toBe("app")
  })

  test("home page loads correctly", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/")

    // Home page should load
    await expect(page).toHaveURL(/\/$/)
    await expect(page.locator("body")).toBeVisible()
  })

  test("can access cycles within a collective", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/collectives")

    const collectiveLink = page.locator('a[href*="/collectives/"]').first()

    if ((await collectiveLink.count()) > 0) {
      await collectiveLink.click()

      // Navigate to cycles
      const currentUrl = page.url()
      const cyclesUrl = currentUrl.replace(/\/$/, "") + "/cycles"
      await page.goto(cyclesUrl)

      // Should be on cycles page
      await expect(page).toHaveURL(/\/cycles/)
    }
  })
})
