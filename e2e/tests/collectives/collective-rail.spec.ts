import { test, expect } from "../../fixtures/test-fixtures"

test.describe("Collective Rail", () => {
  test("rail is hidden on mobile viewports", async ({ authenticatedPage }) => {
    const page = authenticatedPage
    await page.setViewportSize({ width: 375, height: 667 })

    await page.goto("/")

    await expect(page.locator(".pulse-rail")).toBeHidden()
  })

  test("rail stays pinned to the viewport when the page scrolls", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/")

    const rail = page.locator(".pulse-rail")
    await expect(rail).toBeVisible()

    // Make the document taller than the viewport regardless of seeded
    // content, then scroll well past one screen.
    await page.evaluate(() => {
      const spacer = document.createElement("div")
      spacer.style.height = "3000px"
      document.querySelector("main")?.appendChild(spacer)
      window.scrollTo(0, 1500)
    })
    await page.waitForFunction(() => window.scrollY >= 1500)

    const box = await rail.boundingBox()
    expect(box).not.toBeNull()
    // A non-sticky rail scrolls off with the document (top goes negative).
    expect(box!.y).toBeGreaterThanOrEqual(0)
    // The rail spans the viewport, so its own overflow scrolling can work.
    const viewportHeight = page.viewportSize()!.height
    expect(box!.height).toBeGreaterThanOrEqual(viewportHeight - 1)
  })
})
