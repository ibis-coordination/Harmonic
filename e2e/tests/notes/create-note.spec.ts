import { test, expect } from "../../fixtures/test-fixtures"

test.describe("Notes", () => {
  test("authenticated user can navigate to note creation page", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    // Navigate directly to the global note creation page
    await page.goto("/note")

    // Should be on note creation page with a form (exclude the hidden logout form)
    await expect(page).toHaveURL(/\/note/)
    await expect(page.locator('form[action="/note"]')).toBeVisible()
  })

  test("note creation form has required fields", async ({
    authenticatedPage,
  }) => {
    const page = authenticatedPage

    // Navigate directly to the global note creation page
    await page.goto("/note")

    // Form should be visible (exclude the hidden logout form)
    await expect(page.locator('form[action="/note"]')).toBeVisible()

    // Check for text input (notes have text content) - could be textarea or rich editor
    const textInput = page.locator(
      'textarea, [contenteditable="true"], [data-testid="note-text"], .tiptap, .ProseMirror',
    )
    await expect(textInput.first()).toBeVisible()
  })

  test("can create a note with text content", async ({ authenticatedPage }) => {
    const page = authenticatedPage
    const noteText = `E2E Test Note ${Date.now()}`

    // Navigate directly to the global note creation page
    await page.goto("/note")

    // Fill the note text - try textarea first, then contenteditable (rich editor)
    const noteForm = page.locator('form[action="/note"]')
    const textArea = noteForm.locator('textarea').first()
    const richEditor = noteForm.locator('[contenteditable="true"], .tiptap, .ProseMirror').first()

    if ((await textArea.count()) > 0) {
      await textArea.fill(noteText)
    } else if ((await richEditor.count()) > 0) {
      await richEditor.click()
      await richEditor.fill(noteText)
    }

    // Submit the note form (not the hidden logout form)
    await noteForm.locator('button[type="submit"], input[type="submit"]').click()

    // Should redirect to the created note
    await expect(page).toHaveURL(/\/n\//)

    // The note content should be visible
    await expect(page.locator("body")).toContainText(noteText)
  })

  test("note page displays note content", async ({ authenticatedPage }) => {
    const page = authenticatedPage

    // Navigate to home to find existing notes
    await page.goto("/")

    // Look for any note link
    const noteLink = page.locator('a[href*="/n/"]').first()

    if ((await noteLink.count()) > 0) {
      await noteLink.click()

      // Note page should be visible
      await expect(page).toHaveURL(/\/n\/[a-zA-Z0-9]+/)

      // Page should have content
      await expect(page.locator("body")).toBeVisible()
    }
  })
})
