import { test, expect } from "../../fixtures/test-fixtures"

test.describe("Places Sheet", () => {
  test("opens from the tab bar's Places tab on mobile and lists places by name", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage
    await page.setViewportSize({ width: 375, height: 667 })

    await page.goto("/")

    const toggle = page.locator(".pulse-tab-bar-places")
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

  test("the tab bar is hidden on desktop where the rail serves instead", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/")

    await expect(page.locator(".pulse-tab-bar")).toBeHidden()
    await expect(page.locator(".pulse-rail")).toBeVisible()
  })

  test("the tab bar shows its five destinations on mobile and the rail hides", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage
    await page.setViewportSize({ width: 375, height: 667 })

    await page.goto("/")

    const bar = page.locator(".pulse-tab-bar")
    await expect(bar).toBeVisible()
    await expect(page.locator(".pulse-rail")).toBeHidden()
    await expect(bar.locator("a[href='/']")).toBeVisible()
    await expect(bar.locator(".pulse-tab-bar-places")).toBeVisible()
    await expect(bar.locator("a[href='/search']")).toBeVisible()
    await expect(bar.locator("a[href='/notifications']")).toBeVisible()
    await expect(bar.locator(".pulse-tab-bar-you-button")).toBeVisible()

    // You opens the user menu upward.
    await bar.locator(".pulse-tab-bar-you-button").click()
    await expect(bar.locator(".top-menu")).toBeVisible()
    await expect(bar.locator(".top-menu a[href='/help']")).toBeVisible()
  })
})
