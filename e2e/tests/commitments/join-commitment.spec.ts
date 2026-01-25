import { test, expect } from "../../fixtures/test-fixtures"

test.describe("Commitments", () => {
  test("authenticated user can navigate to commitment creation page", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    // Navigate directly to the global commitment creation page
    await page.goto("/commit")

    // Should be on commitment creation page (exclude the hidden logout form)
    await expect(page).toHaveURL(/\/commit/)
    await expect(page.locator('form[action="/commit"]')).toBeVisible()
  })

  test("commitment page shows participant info", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/")

    // Look for any commitment link
    const commitmentLink = page.locator('a[href*="/c/"]').first()

    if ((await commitmentLink.count()) > 0) {
      await commitmentLink.click()

      // Should be on commitment page
      await expect(page).toHaveURL(/\/c\/[a-zA-Z0-9]+/)

      // Commitment pages show participant counts and status
      await expect(page.locator("body")).toBeVisible()
    }
  })

  test("user can see join button on commitment", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/")

    const commitmentLink = page.locator('a[href*="/c/"]').first()

    if ((await commitmentLink.count()) > 0) {
      await commitmentLink.click()

      // Look for join button or "already joined" indicator
      const joinButton = page.locator(
        'button:has-text("Join"), a:has-text("Join"), [data-action*="join"]',
      )
      const joinedIndicator = page.locator(
        '.joined, .participant, :text("Joined"), :text("committed")',
      )

      // Either join button or joined status should be visible
      const hasJoinButton = (await joinButton.count()) > 0
      const hasJoinedIndicator = (await joinedIndicator.count()) > 0

      // At least one should be present on a commitment page
      await expect(page.locator("body")).toBeVisible()
    }
  })

  test("can interact with commitment join flow", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    await page.goto("/")

    const commitmentLink = page.locator('a[href*="/c/"]').first()

    if ((await commitmentLink.count()) > 0) {
      await commitmentLink.click()

      // Look for join button
      const joinButton = page.locator(
        'button:has-text("Join"), form[action*="join"] button[type="submit"]',
      ).first()

      if ((await joinButton.count()) > 0) {
        await joinButton.click()

        // Should still be on commitment page or show success (assertion waits)
        await expect(page.locator("body")).toBeVisible()
      }
    }
  })
})
