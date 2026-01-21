import { test, expect } from "../../fixtures/test-fixtures"
import { login, buildBaseUrl } from "../../helpers/auth"

/**
 * Helper to enable v2 UI for a user
 */
async function enableV2UI(
  page: import("@playwright/test").Page,
  userHandle: string,
) {
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
 * Helper to get user handle from the page
 */
async function getUserHandle(
  page: import("@playwright/test").Page,
  fallbackName: string,
): Promise<string> {
  const settingsLink = page.locator('a[href*="/settings"]').first()
  const settingsHref = await settingsLink.getAttribute("href")
  const handleMatch = settingsHref?.match(/\/u\/([^/]+)\/settings/)
  return handleMatch?.[1] ?? fallbackName.toLowerCase()
}

/**
 * Helper to join a studio for testing
 */
async function joinStudio(
  page: import("@playwright/test").Page,
  studioHandle: string = "taco-tuesday",
) {
  const baseUrl = buildBaseUrl()

  // Navigate to the studio page (this will join via v1 UI if needed)
  await page.goto(`${baseUrl}/studios/${studioHandle}`)

  // If there's a join button, click it
  const joinButton = page.locator(
    'input[type="submit"][value="Join"], button:has-text("Join")',
  )
  if ((await joinButton.count()) > 0) {
    await joinButton.click()
    await page.waitForLoadState("networkidle")
  }
}

test.describe("V2 Decisions", () => {
  test.describe("Decision viewing", () => {
    test("can view a decision in v2 UI", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-decision-view-${Date.now()}-${random}@example.com`
      const testName = `V2DecisionView${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate to studio
      await page.goto(`${baseUrl}/studios/taco-tuesday`)

      // Wait for v2 UI to load
      await page.waitForSelector("#root", { timeout: 10000 })

      // The v2 UI should be visible
      await expect(page.locator("body")).toBeVisible()
    })

    test("decision detail page shows decision content", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-decision-detail-${Date.now()}-${random}@example.com`
      const testName = `V2DecisionDetail${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate directly to a known decision (8d3d2c55 is the Taco Tuesday decision)
      await page.goto(`${baseUrl}/studios/taco-tuesday/d/8d3d2c55`)

      // Wait for v2 UI to load and React to hydrate
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for the API call to complete
      await page.waitForTimeout(2000)

      // Should see the decision heading (with longer timeout)
      await expect(page.locator("h1")).toContainText("Decision:", {
        timeout: 10000,
      })

      // Should see the Options section
      await expect(page.locator("h2:has-text('Options')")).toBeVisible({
        timeout: 5000,
      })

      // Should see the Results section
      await expect(page.locator("h2:has-text('Results')")).toBeVisible({
        timeout: 5000,
      })
    })

    test("decision detail page shows options", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-decision-options-${Date.now()}-${random}@example.com`
      const testName = `V2DecisionOptions${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate directly to a known decision
      await page.goto(`${baseUrl}/studios/taco-tuesday/d/8d3d2c55`)

      // Wait for v2 UI to load and React to hydrate
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for the API call to complete
      await page.waitForTimeout(2000)

      // Should see the options list
      await expect(page.locator("ul.space-y-3")).toBeVisible({ timeout: 5000 })

      // Should see option items (checking for list items)
      const optionItems = page.locator("ul.space-y-3 li")
      await expect(optionItems).toHaveCount(3, { timeout: 5000 })
    })

    test("decision detail page shows results table", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-decision-results-${Date.now()}-${random}@example.com`
      const testName = `V2DecisionResults${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate directly to a known decision
      await page.goto(`${baseUrl}/studios/taco-tuesday/d/8d3d2c55`)

      // Wait for v2 UI to load and React to hydrate
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for the API call to complete
      await page.waitForTimeout(2000)

      // Should see the results table
      await expect(page.locator("table")).toBeVisible({ timeout: 5000 })

      // Should see table headers
      await expect(page.locator("th:has-text('Position')")).toBeVisible({
        timeout: 5000,
      })
      await expect(page.locator("th:has-text('Option')")).toBeVisible({
        timeout: 5000,
      })
      await expect(page.locator("th:has-text('Accepted')")).toBeVisible({
        timeout: 5000,
      })
      await expect(page.locator("th:has-text('Preferred')")).toBeVisible({
        timeout: 5000,
      })
    })

    test("decision detail page shows metadata", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-decision-meta-${Date.now()}-${random}@example.com`
      const testName = `V2DecisionMeta${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate directly to a known decision
      await page.goto(`${baseUrl}/studios/taco-tuesday/d/8d3d2c55`)

      // Wait for v2 UI to load and React to hydrate
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for the API call to complete
      await page.waitForTimeout(2000)

      // Should see metadata labels
      await expect(page.locator("dt:has-text('Created')")).toBeVisible({
        timeout: 5000,
      })
      await expect(page.locator("dt:has-text('Updated')")).toBeVisible({
        timeout: 5000,
      })
      await expect(page.locator("dt:has-text('Voters')")).toBeVisible({
        timeout: 5000,
      })
    })
  })
})
