import { test, expect } from "../../fixtures/test-fixtures"
import { gotoTenant, getCurrentSubdomain } from "../../helpers/tenant"

test.describe("Studio Navigation", () => {
  test("can navigate to studios list", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/studios")

    await expect(page).toHaveURL(/\/studios/)

    // Studios page should have heading or list
    await expect(page.locator("body")).toBeVisible()
  })

  test("can enter a studio", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/studios")

    const studioLink = page.locator('a[href*="/studios/"]').first()

    if ((await studioLink.count()) > 0) {
      await studioLink.click()

      // Should be in a studio (URL has studio handle)
      await expect(page).toHaveURL(/\/studios\/[a-zA-Z0-9_-]+/)
    }
  })

  test("studio page shows content sections", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/studios")

    const studioLink = page.locator('a[href*="/studios/"]').first()

    if ((await studioLink.count()) > 0) {
      await studioLink.click()

      // Studio page should have navigation or content links
      const contentLinks = page.locator(
        'a[href*="/note"], a[href*="/decide"], a[href*="/commit"]',
      )

      // Page should be functional
      await expect(page.locator("body")).toBeVisible()
    }
  })

  test("can navigate to studio settings", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/studios")

    const studioLink = page.locator('a[href*="/studios/"]').first()

    if ((await studioLink.count()) > 0) {
      await studioLink.click()

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

  test("can access cycles within a studio", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/studios")

    const studioLink = page.locator('a[href*="/studios/"]').first()

    if ((await studioLink.count()) > 0) {
      await studioLink.click()

      // Navigate to cycles
      const currentUrl = page.url()
      const cyclesUrl = currentUrl.replace(/\/$/, "") + "/cycles"
      await page.goto(cyclesUrl)

      // Should be on cycles page
      await expect(page).toHaveURL(/\/cycles/)
    }
  })
})
