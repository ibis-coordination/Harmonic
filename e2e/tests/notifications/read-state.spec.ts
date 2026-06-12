import { test, expect } from "../../fixtures/test-fixtures"

test.describe("Notifications read state", () => {
  test("unread notification can be marked read, then dismissed", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/notifications")

    // e2e:setup seeds an unread notification for the test user
    const unreadRow = page.locator(".pulse-notification-unread").first()
    await expect(unreadRow).toBeVisible()
    const rowId = await unreadRow.getAttribute("data-notification-item")
    expect(rowId).toBeTruthy()

    const row = page.locator(`[data-notification-item="${rowId}"]`)
    await expect(row.locator(".pulse-notification-indicator")).toBeVisible()

    // Mark read: the row stays but loses its unread styling and controls
    await row.locator("[data-mark-read-button]").click()
    await expect(row).toBeVisible()
    await expect(row).not.toHaveClass(/pulse-notification-unread/)
    await expect(row.locator(".pulse-notification-indicator")).toHaveCount(0)
    await expect(row.locator("[data-mark-read-button]")).toHaveCount(0)

    // The read state survives a reload (persisted server-side)
    await page.reload()
    const reloadedRow = page.locator(`[data-notification-item="${rowId}"]`)
    await expect(reloadedRow).toBeVisible()
    await expect(reloadedRow).not.toHaveClass(/pulse-notification-unread/)

    // Dismiss: the row is removed
    await reloadedRow.locator('button[title="Dismiss"]').click()
    await expect(
      page.locator(`[data-notification-item="${rowId}"]`),
    ).toHaveCount(0)

    // ...and stays gone after a reload
    await page.reload()
    await expect(
      page.locator(`[data-notification-item="${rowId}"]`),
    ).toHaveCount(0)
  })
})
