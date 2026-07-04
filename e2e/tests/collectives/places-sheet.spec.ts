import { test, expect } from "../../fixtures/test-fixtures"

test.describe("Places Sheet", () => {
  test("opens from the header toggle on mobile and lists places by name", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage
    await page.setViewportSize({ width: 375, height: 667 })

    await page.goto("/")

    const toggle = page.locator(".pulse-places-toggle")
    await expect(toggle).toBeVisible()

    const sheet = page.locator(".pulse-places-sheet")
    await expect(sheet).toBeHidden()

    await toggle.click()
    await expect(sheet).toBeVisible()
    // data-place-path, not href: a badged entry's href swaps to the
    // my:notified view, and the e2e user may have main-collective unread.
    await expect(sheet.locator("a[data-place-path='/']")).toContainText("Public space")
    await expect(sheet.locator("a[href='/chat']")).toContainText("Chat")
    await expect(sheet.locator("a[href='/collectives']")).toContainText(
      "Create or join a collective",
    )

    await page.keyboard.press("Escape")
    await expect(sheet).toBeHidden()
  })

  test("the toggle is hidden on desktop where the rail serves instead", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/")

    await expect(page.locator(".pulse-places-toggle")).toBeHidden()
    await expect(page.locator(".pulse-rail")).toBeVisible()
  })
})
