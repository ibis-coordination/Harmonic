import { test, expect } from "@playwright/test"

// Storybook tests run against the built static storybook
const STORYBOOK_URL = "http://localhost:6006"

test.describe("Storybook - DecisionDetail", () => {
  test.skip(
    ({ browserName }) => browserName !== "chromium",
    "Storybook tests only run in Chromium",
  )

  test.beforeEach(async ({ page }) => {
    // Navigate to the Storybook iframe directly for faster tests
    await page.goto(STORYBOOK_URL, { timeout: 30000 })
    // Wait for Storybook to load
    await page.waitForSelector('[id="storybook-preview-wrapper"]', {
      timeout: 30000,
    })
  })

  test("Default story renders decision with options and results", async ({
    page,
  }) => {
    // Navigate to the DecisionDetail Default story
    await page.goto(
      `${STORYBOOK_URL}/?path=/story/components-decisiondetail--default`,
      { timeout: 30000 },
    )

    // Wait for the story to load in the iframe
    const iframe = page.frameLocator("#storybook-preview-iframe")

    // Should see the decision heading
    await expect(iframe.locator("h1")).toContainText("Decision:", {
      timeout: 10000,
    })
    await expect(iframe.locator("h1")).toContainText("Taco Tuesday", {
      timeout: 5000,
    })

    // Should see Options section
    await expect(iframe.locator("h2:has-text('Options')")).toBeVisible({
      timeout: 5000,
    })

    // Should see Results section
    await expect(iframe.locator("h2:has-text('Results')")).toBeVisible({
      timeout: 5000,
    })

    // Should see option items
    await expect(iframe.locator("text=Carnitas")).toBeVisible({ timeout: 5000 })
    await expect(iframe.locator("text=Barbacoa")).toBeVisible({ timeout: 5000 })
    await expect(iframe.locator("text=Al Pastor")).toBeVisible({
      timeout: 5000,
    })
  })

  test("Loading story shows loading state", async ({ page }) => {
    // Navigate to the DecisionDetail Loading story
    await page.goto(
      `${STORYBOOK_URL}/?path=/story/components-decisiondetail--loading`,
      { timeout: 30000 },
    )

    // Wait for the story to load in the iframe
    const iframe = page.frameLocator("#storybook-preview-iframe")

    // Should see loading text
    await expect(iframe.locator("text=Loading")).toBeVisible({ timeout: 10000 })
  })

  test("Error story shows error state", async ({ page }) => {
    // Navigate to the DecisionDetail Error story
    await page.goto(
      `${STORYBOOK_URL}/?path=/story/components-decisiondetail--error`,
      { timeout: 30000 },
    )

    // Wait for the story to load in the iframe
    const iframe = page.frameLocator("#storybook-preview-iframe")

    // Should see error text
    await expect(iframe.locator("text=Error")).toBeVisible({ timeout: 10000 })
  })

  test("NoDescription story renders without description section", async ({
    page,
  }) => {
    // Navigate to the DecisionDetail NoDescription story
    await page.goto(
      `${STORYBOOK_URL}/?path=/story/components-decisiondetail--no-description`,
      { timeout: 30000 },
    )

    // Wait for the story to load in the iframe
    const iframe = page.frameLocator("#storybook-preview-iframe")

    // Should see the decision heading
    await expect(iframe.locator("h1")).toContainText("Decision:", {
      timeout: 10000,
    })

    // Should NOT see Description section
    await expect(
      iframe.locator("h2:has-text('Description')"),
    ).not.toBeVisible({ timeout: 3000 })

    // Should still see Options and Results sections
    await expect(iframe.locator("h2:has-text('Options')")).toBeVisible({
      timeout: 5000,
    })
    await expect(iframe.locator("h2:has-text('Results')")).toBeVisible({
      timeout: 5000,
    })
  })

  test("NoOptions story shows empty options state", async ({ page }) => {
    // Navigate to the DecisionDetail NoOptions story
    await page.goto(
      `${STORYBOOK_URL}/?path=/story/components-decisiondetail--no-options`,
      { timeout: 30000 },
    )

    // Wait for the story to load in the iframe
    const iframe = page.frameLocator("#storybook-preview-iframe")

    // Should see the decision heading
    await expect(iframe.locator("h1")).toContainText("Decision:", {
      timeout: 10000,
    })

    // Should see "No options yet" message
    await expect(iframe.locator("text=No options yet")).toBeVisible({
      timeout: 5000,
    })
  })

  test("NoVotes story shows empty votes state", async ({ page }) => {
    // Navigate to the DecisionDetail NoVotes story
    await page.goto(
      `${STORYBOOK_URL}/?path=/story/components-decisiondetail--no-votes`,
      { timeout: 30000 },
    )

    // Wait for the story to load in the iframe
    const iframe = page.frameLocator("#storybook-preview-iframe")

    // Should see the decision heading
    await expect(iframe.locator("h1")).toContainText("Decision:", {
      timeout: 10000,
    })

    // Should see "No votes yet" message
    await expect(iframe.locator("text=No votes yet")).toBeVisible({
      timeout: 5000,
    })
  })

  test("NoDeadline story renders without deadline", async ({ page }) => {
    // Navigate to the DecisionDetail NoDeadline story
    await page.goto(
      `${STORYBOOK_URL}/?path=/story/components-decisiondetail--no-deadline`,
      { timeout: 30000 },
    )

    // Wait for the story to load in the iframe
    const iframe = page.frameLocator("#storybook-preview-iframe")

    // Should see the decision heading
    await expect(iframe.locator("h1")).toContainText("Decision:", {
      timeout: 10000,
    })

    // Should NOT see Deadline label
    await expect(iframe.locator("dt:has-text('Deadline')")).not.toBeVisible({
      timeout: 3000,
    })

    // Should still see Created and Updated labels
    await expect(iframe.locator("dt:has-text('Created')")).toBeVisible({
      timeout: 5000,
    })
    await expect(iframe.locator("dt:has-text('Updated')")).toBeVisible({
      timeout: 5000,
    })
  })
})
