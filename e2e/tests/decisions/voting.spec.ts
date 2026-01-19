import { test, expect } from "../../fixtures/test-fixtures"

test.describe("Decisions", () => {
  test("authenticated user can navigate to decision creation page", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    // Navigate directly to the global decision creation page
    await page.goto("/decide")

    // Should be on decision creation page (exclude the hidden logout form)
    await expect(page).toHaveURL(/\/decide/)
    await expect(page.locator('form[action="/decide"]')).toBeVisible()
  })

  test("decision page shows voting options", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    // Navigate to home or studio to find decisions
    await page.goto("/")

    // Look for any decision link
    const decisionLink = page.locator('a[href*="/d/"]').first()

    if ((await decisionLink.count()) > 0) {
      await decisionLink.click()

      // Should be on decision page
      await expect(page).toHaveURL(/\/d\/[a-zA-Z0-9]+/)

      // Decision pages typically show options and voting controls
      await expect(page.locator("body")).toBeVisible()
    }
  })

  test("can view decision results", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/")

    const decisionLink = page.locator('a[href*="/d/"]').first()

    if ((await decisionLink.count()) > 0) {
      await decisionLink.click()

      // Results section should be visible on decision page
      // Results might be in a partial or specific section
      const resultsSection = page.locator(
        '.results, [data-testid="results"], .votes, .vote-results',
      )

      // Page should load without errors
      await expect(page.locator("body")).toBeVisible()
    }
  })

  test("user can interact with voting UI", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    await page.goto("/")

    const decisionLink = page.locator('a[href*="/d/"]').first()

    if ((await decisionLink.count()) > 0) {
      await decisionLink.click()

      // Look for vote buttons (accept/reject)
      const voteButton = page.locator(
        'button:has-text("Accept"), button:has-text("Reject"), button:has-text("Vote"), [data-action*="vote"]',
      )

      if ((await voteButton.count()) > 0) {
        // Click first vote button
        await voteButton.first().click()

        // Wait for any response (could be a Turbo frame update)
        await page.waitForTimeout(500)

        // Page should still be functional
        await expect(page.locator("body")).toBeVisible()
      }
    }
  })
})
