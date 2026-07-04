import { test, expect } from "../../fixtures/test-fixtures"

// iOS Safari zooms the viewport when a focused text control's computed
// font-size is under 16px. The guard lives in _responsive.css; these specs
// pin it against class-based font-size overrides (issue #392: the feed bar's
// textarea regressed because its 13px class outranked the bare `textarea`
// element selector).

const fontSize = async (locator: import("@playwright/test").Locator) =>
  parseFloat(await locator.evaluate((el) => getComputedStyle(el).fontSize))

test.describe("Mobile input font-size (iOS autozoom guard)", () => {
  test("feed bar query textarea is at least 16px on mobile", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage
    await page.setViewportSize({ width: 375, height: 667 })
    await page.goto("/")

    const input = page.locator("textarea.pulse-feed-bar-input")
    await expect(input).toBeVisible()
    expect(await fontSize(input)).toBeGreaterThanOrEqual(16)
  })

  test("feed bar query textarea keeps its compact size on desktop", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage
    await page.setViewportSize({ width: 1280, height: 800 })
    await page.goto("/")

    const input = page.locator("textarea.pulse-feed-bar-input")
    await expect(input).toBeVisible()
    expect(await fontSize(input)).toBeLessThan(16)
  })
})
