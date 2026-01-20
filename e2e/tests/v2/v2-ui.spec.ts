import { test, expect } from "../../fixtures/test-fixtures"
import { login, buildBaseUrl } from "../../helpers/auth"

/**
 * Helper to enable v2 UI for a user
 */
async function enableV2UI(page: import("@playwright/test").Page, userHandle: string) {
  const baseUrl = buildBaseUrl()

  // Navigate to user settings
  await page.goto(`${baseUrl}/u/${userHandle}/settings`)

  // Click the v2 button to enable v2 UI
  const v2Button = page.locator('input[type="submit"][value="v2 (Beta)"]')

  // Check if v2 is already enabled (button would be disabled)
  const isDisabled = await v2Button.isDisabled()
  if (!isDisabled) {
    await v2Button.click()
    // Wait for form submission
    await page.waitForLoadState("networkidle")
  }
}

/**
 * Helper to disable v2 UI (switch back to v1)
 */
async function disableV2UI(page: import("@playwright/test").Page, userHandle: string) {
  const baseUrl = buildBaseUrl()

  // Navigate to user settings
  await page.goto(`${baseUrl}/u/${userHandle}/settings`)

  // Click the v1 button
  const v1Button = page.locator('input[type="submit"][value="v1 (Classic)"]')

  const isDisabled = await v1Button.isDisabled()
  if (!isDisabled) {
    await v1Button.click()
    await page.waitForLoadState("networkidle")
  }
}

test.describe("V2 UI", () => {
  test.describe("UI version toggle", () => {
    test("user can enable v2 UI from settings", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-toggle-${Date.now()}-${random}@example.com`
      const testName = `V2User${random}`

      await login(page, { email: testEmail, name: testName })

      // Get user handle from the page (it's derived from name)
      const baseUrl = buildBaseUrl()

      // Go to home and find settings link to determine handle
      await page.goto(baseUrl)

      // Find the Settings link to get the user handle
      const settingsLink = page.locator('a[href*="/settings"]').first()
      const settingsHref = await settingsLink.getAttribute("href")
      const handleMatch = settingsHref?.match(/\/u\/([^/]+)\/settings/)
      const userHandle = handleMatch?.[1] ?? testName.toLowerCase()

      // Navigate to settings
      await page.goto(`${baseUrl}/u/${userHandle}/settings`)

      // Should see the UI Version section
      await expect(page.locator("text=UI Version")).toBeVisible()

      // Should see both v1 and v2 buttons
      await expect(
        page.locator('input[value="v1 (Classic)"]'),
      ).toBeVisible()
      await expect(page.locator('input[value="v2 (Beta)"]')).toBeVisible()

      // Click v2 button
      await page.locator('input[value="v2 (Beta)"]').click()
      await page.waitForLoadState("networkidle")

      // Navigate to home to verify v2 UI is active
      // (settings page still uses v1 layout after toggle)
      await page.goto(baseUrl)

      // Wait for React to hydrate
      await page.waitForSelector("#root", { timeout: 10000 })

      // Should see the v2 welcome message on home page
      await expect(page.locator("text=Welcome to Harmonic")).toBeVisible({
        timeout: 10000,
      })
    })
  })

  test.describe("V2 React app", () => {
    test("v2 UI loads and shows welcome message", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-app-${Date.now()}-${random}@example.com`
      const testName = `V2App${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      // Get user handle
      const settingsLink = page.locator('a[href*="/settings"]').first()
      const settingsHref = await settingsLink.getAttribute("href")
      const handleMatch = settingsHref?.match(/\/u\/([^/]+)\/settings/)
      const userHandle = handleMatch?.[1] ?? testName.toLowerCase()

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Refresh to load v2 UI
      await page.goto(baseUrl)

      // V2 UI should show the React welcome page
      // Wait for React to hydrate
      await page.waitForSelector("#root", { timeout: 10000 })

      // Should see v2-specific content
      await expect(page.locator("text=Welcome to Harmonic")).toBeVisible({
        timeout: 10000,
      })
      await expect(
        page.locator("text=You're using the beta version"),
      ).toBeVisible()
    })

    test("v2 UI renders header with user info", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-header-${Date.now()}-${random}@example.com`
      const testName = `V2Header${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      // Get user handle
      const settingsLink = page.locator('a[href*="/settings"]').first()
      const settingsHref = await settingsLink.getAttribute("href")
      const handleMatch = settingsHref?.match(/\/u\/([^/]+)\/settings/)
      const userHandle = handleMatch?.[1] ?? testName.toLowerCase()

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Refresh to load v2 UI
      await page.goto(baseUrl)

      // Wait for React to hydrate
      await page.waitForSelector("#root", { timeout: 10000 })

      // Should see the Harmonic link in header (using exact match to avoid matching tenant name)
      await expect(
        page.getByRole("link", { name: "Harmonic", exact: true }),
      ).toBeVisible({
        timeout: 10000,
      })

      // Should see user display name
      await expect(page.locator(`text=${testName}`)).toBeVisible()

      // Should see Settings and Sign out links
      await expect(page.locator("header >> text=Settings")).toBeVisible()
      await expect(page.locator("header >> text=Sign out")).toBeVisible()
    })

    test("user can switch back to v1", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-switch-${Date.now()}-${random}@example.com`
      const testName = `V2Switch${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      // Get user handle
      const settingsLink = page.locator('a[href*="/settings"]').first()
      const settingsHref = await settingsLink.getAttribute("href")
      const handleMatch = settingsHref?.match(/\/u\/([^/]+)\/settings/)
      const userHandle = handleMatch?.[1] ?? testName.toLowerCase()

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Verify v2 is active
      await page.goto(baseUrl)
      await page.waitForSelector("#root", { timeout: 10000 })
      await expect(page.locator("text=Welcome to Harmonic")).toBeVisible({
        timeout: 10000,
      })

      // Navigate directly to settings page to switch back
      // Note: The v2 UI doesn't have a settings route yet, so we navigate directly
      await disableV2UI(page, userHandle)

      // Refresh to load v1 UI
      await page.goto(baseUrl)

      // Should NOT see the v2 welcome message
      await expect(
        page.locator("text=Welcome to Harmonic"),
      ).not.toBeVisible({ timeout: 5000 })
    })
  })

  test.describe("V2 navigation", () => {
    test("v2 header logo links to home", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-nav-${Date.now()}-${random}@example.com`
      const testName = `V2Nav${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      // Get user handle
      const settingsLink = page.locator('a[href*="/settings"]').first()
      const settingsHref = await settingsLink.getAttribute("href")
      const handleMatch = settingsHref?.match(/\/u\/([^/]+)\/settings/)
      const userHandle = handleMatch?.[1] ?? testName.toLowerCase()

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Refresh to load v2 UI
      await page.goto(baseUrl)

      // Wait for React to hydrate
      await page.waitForSelector("#root", { timeout: 10000 })

      // Click on the Harmonic logo (using exact match to avoid matching tenant name)
      await page.getByRole("link", { name: "Harmonic", exact: true }).click()

      // Should still be on home page (React handles this client-side)
      await expect(page).toHaveURL(/\/$/)
      await expect(page.locator("text=Welcome to Harmonic")).toBeVisible()
    })
  })
})
