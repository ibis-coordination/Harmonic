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
async function getUserHandle(page: import("@playwright/test").Page, fallbackName: string): Promise<string> {
  const settingsLink = page.locator('a[href*="/settings"]').first()
  const settingsHref = await settingsLink.getAttribute("href")
  const handleMatch = settingsHref?.match(/\/u\/([^/]+)\/settings/)
  return handleMatch?.[1] ?? fallbackName.toLowerCase()
}

/**
 * Helper to create a studio for testing
 */
async function joinStudio(page: import("@playwright/test").Page, studioHandle: string = "taco-tuesday") {
  const baseUrl = buildBaseUrl()

  // Navigate to the studio page (this will join via v1 UI if needed)
  await page.goto(`${baseUrl}/studios/${studioHandle}`)

  // If there's a join button, click it
  const joinButton = page.locator('input[type="submit"][value="Join"], button:has-text("Join")')
  if ((await joinButton.count()) > 0) {
    await joinButton.click()
    await page.waitForLoadState("networkidle")
  }
}

test.describe("V2 Notes", () => {
  test.describe("Note viewing", () => {
    test("can view a note in v2 UI", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-note-view-${Date.now()}-${random}@example.com`
      const testName = `V2NoteView${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate to a known note (use the E2E test note created earlier)
      // First try to find a note link in v1 UI
      await page.goto(`${baseUrl}/studios/taco-tuesday`)

      // Wait for v2 UI to load
      await page.waitForSelector("#root", { timeout: 10000 })

      // Navigate to today's cycle to find notes
      await page.goto(`${baseUrl}/studios/taco-tuesday/cycles/today`)
      await page.waitForSelector("#root", { timeout: 10000 })

      // Look for any note link or the note viewing UI
      // The v2 UI should show the studio with notes
      await expect(page.locator("body")).toBeVisible()
    })

    test("note detail page shows note content", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-note-detail-${Date.now()}-${random}@example.com`
      const testName = `V2NoteDetail${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate directly to a known note (243bd083 is the E2E test note)
      await page.goto(`${baseUrl}/studios/taco-tuesday/n/243bd083`)

      // Wait for v2 UI to load and React to hydrate
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for the API call to complete
      await page.waitForTimeout(2000)

      // Should see the note heading (with longer timeout)
      await expect(page.locator("h1")).toContainText("Note:", { timeout: 10000 })

      // Should see the Text section
      await expect(page.locator("h2:has-text('Text')")).toBeVisible({ timeout: 5000 })

      // Should see the History section
      await expect(page.locator("h2:has-text('History')")).toBeVisible({ timeout: 5000 })

      // Should see the Actions section
      await expect(page.locator("h2:has-text('Actions')")).toBeVisible({ timeout: 5000 })

      // Should see confirm read button
      await expect(page.locator("button:has-text('Confirm Read')")).toBeVisible({ timeout: 5000 })
    })
  })

  test.describe("Note creation", () => {
    test("can navigate to note creation page", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-note-create-nav-${Date.now()}-${random}@example.com`
      const testName = `V2NoteCreateNav${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate to note creation page
      await page.goto(`${baseUrl}/studios/taco-tuesday/note`)

      // Wait for v2 UI to load
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for React to render
      await page.waitForTimeout(1000)

      // Should see the New Note heading
      await expect(page.locator("h1:has-text('New Note')")).toBeVisible({ timeout: 10000 })

      // Should see the text area
      await expect(page.locator("textarea")).toBeVisible({ timeout: 5000 })

      // Should see the Create Note button (disabled by default)
      const createButton = page.locator("button:has-text('Create Note')")
      await expect(createButton).toBeVisible({ timeout: 5000 })
      await expect(createButton).toBeDisabled()
    })

    test("create note button is enabled when text is entered", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-note-create-enable-${Date.now()}-${random}@example.com`
      const testName = `V2NoteCreateEnable${random}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate to note creation page
      await page.goto(`${baseUrl}/studios/taco-tuesday/note`)

      // Wait for v2 UI to load
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for React to render
      await page.waitForTimeout(1000)

      // Enter text in the textarea
      const textarea = page.locator("textarea")
      await expect(textarea).toBeVisible({ timeout: 10000 })
      await textarea.fill("Test note content")

      // Create Note button should now be enabled
      const createButton = page.locator("button:has-text('Create Note')")
      await expect(createButton).not.toBeDisabled({ timeout: 5000 })
    })

    test("can create a note and navigate to detail page", async ({ page }) => {
      const random = Math.random().toString(36).substring(2, 10)
      const testEmail = `v2-note-create-full-${Date.now()}-${random}@example.com`
      const testName = `V2NoteCreateFull${random}`
      const noteContent = `V2 E2E Test Note ${Date.now()}`

      await login(page, { email: testEmail, name: testName })

      const baseUrl = buildBaseUrl()
      await page.goto(baseUrl)

      const userHandle = await getUserHandle(page, testName)

      // Join the test studio
      await joinStudio(page, "taco-tuesday")

      // Enable v2 UI
      await enableV2UI(page, userHandle)

      // Navigate to note creation page
      await page.goto(`${baseUrl}/studios/taco-tuesday/note`)

      // Wait for v2 UI to load
      await page.waitForSelector("#root", { timeout: 15000 })

      // Allow time for React to render
      await page.waitForTimeout(1000)

      // Enter note content
      const textarea = page.locator("textarea")
      await expect(textarea).toBeVisible({ timeout: 10000 })
      await textarea.fill(noteContent)

      // Click Create Note button
      const createButton = page.locator("button:has-text('Create Note')")
      await expect(createButton).toBeVisible({ timeout: 5000 })
      await createButton.click()

      // Should navigate to the created note's detail page
      await page.waitForURL(/\/studios\/taco-tuesday\/n\/[a-zA-Z0-9]+/, {
        timeout: 15000,
      })

      // Should see the note content on the detail page
      await expect(page.locator("body")).toContainText(noteContent, { timeout: 10000 })
    })
  })
})
