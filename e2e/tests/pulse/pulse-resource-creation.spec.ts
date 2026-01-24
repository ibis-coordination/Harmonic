import { test, expect } from "../../fixtures/test-fixtures"
import { buildBaseUrl } from "../../helpers/auth"

// Cache studio path across all tests - fetched once in beforeAll
let cachedStudioPath: string | null = null

test.describe("Pulse Resource Creation Forms", () => {
  // Get studio path once before all tests
  test.beforeAll(async ({ browser }) => {
    const baseUrl = buildBaseUrl()
    const context = await browser.newContext({
      storageState: "e2e/.auth/user.json",
    })
    const page = await context.newPage()

    await page.goto(`${baseUrl}/studios`)
    await page.waitForLoadState("domcontentloaded")

    const studioLink = page.locator('a[href*="/studios/"]').first()
    if ((await studioLink.count()) > 0) {
      const href = await studioLink.getAttribute("href")
      const match = href?.match(/\/studios\/[^/]+/)
      cachedStudioPath = match ? match[0] : null
    }

    await context.close()
  })
  test.describe("Note Creation", () => {
    test("can navigate to note creation from studio", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage

      if (!cachedStudioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()

      // Navigate to studio page (Pulse)
      await page.goto(`${baseUrl}${cachedStudioPath}`)
      await page.waitForLoadState("domcontentloaded")

      // Click the "+ New" button in the header
      const newButton = page.locator('a.pulse-action-btn:has-text("+ New")')
      await expect(newButton).toBeVisible()
      await newButton.click()

      // Should be on note creation page (route is /note, not /notes/new)
      await expect(page).toHaveURL(/\/note/)

      // Page should show note form with Pulse styling
      await expect(page.locator(".pulse-resource-detail")).toBeVisible()
      await expect(page.locator("h1.pulse-resource-title")).toContainText("New Note")
    })

    test("note form has required elements", async ({ authenticatedPage }) => {
      const page = authenticatedPage

      if (!cachedStudioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      // Route is /note, not /notes/new
      await page.goto(`${baseUrl}${cachedStudioPath}/note`)
      await page.waitForLoadState("domcontentloaded")

      // Check for form elements
      const form = page.locator("form.pulse-form")
      await expect(form).toBeVisible()

      // Text area for note content
      const textarea = form.locator('textarea[name="text"]')
      await expect(textarea).toBeVisible()
      await expect(textarea).toHaveClass(/pulse-form-textarea/)

      // Submit button
      const submitBtn = form.locator('input[type="submit"][value="Post Note"]')
      await expect(submitBtn).toBeVisible()
      await expect(submitBtn).toHaveClass(/pulse-action-btn/)

      // Visibility hint
      const visibilityHint = form.locator(".pulse-visibility-hint")
      await expect(visibilityHint).toBeVisible()
    })

    test("note form shows breadcrumb navigation", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage

      if (!cachedStudioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${cachedStudioPath}/note`)
      await page.waitForLoadState("domcontentloaded")

      // Check breadcrumb (use nav element to be specific about which one)
      const breadcrumb = page.locator("nav.pulse-breadcrumb")
      await expect(breadcrumb).toBeVisible()

      // Should have studio link and "New Note" text
      const studioLink = breadcrumb.locator("a").first()
      await expect(studioLink).toBeVisible()

      await expect(breadcrumb).toContainText("New Note")
    })

    test("can create a note", async ({ authenticatedPage }) => {
      const page = authenticatedPage

      if (!cachedStudioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${cachedStudioPath}/note`)
      await page.waitForLoadState("domcontentloaded")

      const noteText = `E2E Pulse Note Test ${Date.now()}`

      // Fill the note text
      const textarea = page.locator('textarea[name="text"]')
      await textarea.fill(noteText)

      // Submit the form
      await page.locator('input[type="submit"][value="Post Note"]').click()

      // Should redirect to the created note
      await expect(page).toHaveURL(/\/n\//)
      await page.waitForLoadState("domcontentloaded")

      // The note content should be visible
      await expect(page.locator("body")).toContainText(noteText)

      // Should show Pulse styling
      await expect(page.locator(".pulse-resource-detail")).toBeVisible()
    })

    test("note form uses resource sidebar mode", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage

      if (!cachedStudioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${cachedStudioPath}/note`)
      await page.waitForLoadState("domcontentloaded")

      // Sidebar should be in resource mode (minimal with back link)
      const sidebar = page.locator('.pulse-sidebar[data-mode="resource"]')
      await expect(sidebar).toBeVisible()

      // Should have back link to studio
      const backLink = sidebar.locator('.pulse-nav-item:has-text("Back to")')
      await expect(backLink).toBeVisible()
    })
  })

  test.describe("Decision Creation", () => {
    test("can navigate to decision creation from studio", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage

      if (!cachedStudioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      // Route is /decide, not /decisions/new
      await page.goto(`${baseUrl}${cachedStudioPath}/decide`)
      await page.waitForLoadState("domcontentloaded")

      // Page should show decision form with Pulse styling
      await expect(page.locator(".pulse-resource-detail")).toBeVisible()
      await expect(page.locator("h1.pulse-resource-title")).toContainText("New Decision")
    })

    test("decision form has required elements", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/decide`)
      await page.waitForLoadState("domcontentloaded")

      // Check for form elements
      const form = page.locator("form.pulse-form")
      await expect(form).toBeVisible()

      // Question input field
      const questionInput = form.locator('input[name="question"]')
      await expect(questionInput).toBeVisible()
      await expect(questionInput).toHaveClass(/pulse-form-input/)

      // Description textarea
      const descriptionArea = form.locator('textarea[name="description"]')
      await expect(descriptionArea).toBeVisible()
      await expect(descriptionArea).toHaveClass(/pulse-form-textarea/)

      // Options section
      const optionsSection = form.locator('.pulse-form-section:has-text("Options")')
      await expect(optionsSection).toBeVisible()

      // Options select dropdown
      const optionsSelect = form.locator('select[name="options_open"]')
      await expect(optionsSelect).toBeVisible()

      // Deadline section
      const deadlineSection = form.locator('.pulse-form-section:has-text("Deadline")')
      await expect(deadlineSection).toBeVisible()

      // Deadline radio options
      const deadlineOptions = form.locator(".pulse-deadline-options")
      await expect(deadlineOptions).toBeVisible()

      // Submit button
      const submitBtn = form.locator('input[type="submit"][value="Start Decision"]')
      await expect(submitBtn).toBeVisible()
      await expect(submitBtn).toHaveClass(/pulse-action-btn/)

      // Visibility hint
      const visibilityHint = form.locator(".pulse-visibility-hint")
      await expect(visibilityHint).toBeVisible()
    })

    test("decision form shows breadcrumb navigation", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/decide`)
      await page.waitForLoadState("domcontentloaded")

      // Check breadcrumb
      const breadcrumb = page.locator("nav.pulse-breadcrumb")
      await expect(breadcrumb).toBeVisible()
      await expect(breadcrumb).toContainText("New Decision")
    })

    test("decision deadline options work correctly", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/decide`)
      await page.waitForLoadState("domcontentloaded")

      // Check deadline radio options
      const noDeadlineRadio = page.locator('input[name="deadline_option"][value="no_deadline"]')
      const datetimeRadio = page.locator('input[name="deadline_option"][value="datetime"]')

      await expect(noDeadlineRadio).toBeVisible()
      await expect(datetimeRadio).toBeVisible()

      // Click no deadline option
      await noDeadlineRadio.click()
      await expect(noDeadlineRadio).toBeChecked()

      // Click datetime option
      await datetimeRadio.click()
      await expect(datetimeRadio).toBeChecked()

      // Datetime input should be visible
      const datetimeInput = page.locator('input[name="deadline"][type="datetime-local"]')
      await expect(datetimeInput).toBeVisible()
    })

    test("can create a decision", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/decide`)
      await page.waitForLoadState("domcontentloaded")

      const questionText = `E2E Decision Test ${Date.now()}?`
      const descriptionText = "This is a test decision created by e2e tests"

      // Fill the question
      await page.locator('input[name="question"]').fill(questionText)

      // Fill the description
      await page.locator('textarea[name="description"]').fill(descriptionText)

      // Select "Everyone" for options (should be default)
      await expect(page.locator('select[name="options_open"]')).toHaveValue("true")

      // Submit the form
      await page.locator('input[type="submit"][value="Start Decision"]').click()

      // Should redirect to the created decision
      await expect(page).toHaveURL(/\/d\//)
      await page.waitForLoadState("domcontentloaded")

      // The decision question should be visible
      await expect(page.locator("body")).toContainText(questionText)

      // Should show Pulse styling
      await expect(page.locator(".pulse-resource-detail")).toBeVisible()
    })

    test("decision form uses resource sidebar mode", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/decide`)
      await page.waitForLoadState("domcontentloaded")

      // Sidebar should be in resource mode
      const sidebar = page.locator('.pulse-sidebar[data-mode="resource"]')
      await expect(sidebar).toBeVisible()
    })
  })

  test.describe("Commitment Creation", () => {
    test("can navigate to commitment creation from studio", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      // Route is /commit, not /commitments/new
      await page.goto(`${baseUrl}${studioPath}/commit`)
      await page.waitForLoadState("domcontentloaded")

      // Page should show commitment form with Pulse styling
      await expect(page.locator(".pulse-resource-detail")).toBeVisible()
      await expect(page.locator("h1.pulse-resource-title")).toContainText("New Commitment")
    })

    test("commitment form has required elements", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/commit`)
      await page.waitForLoadState("domcontentloaded")

      // Check for form elements
      const form = page.locator("form.pulse-form")
      await expect(form).toBeVisible()

      // Title input field
      const titleInput = form.locator('input[name="title"]')
      await expect(titleInput).toBeVisible()
      await expect(titleInput).toHaveClass(/pulse-form-input/)

      // Description textarea
      const descriptionArea = form.locator('textarea[name="description"]')
      await expect(descriptionArea).toBeVisible()
      await expect(descriptionArea).toHaveClass(/pulse-form-textarea/)

      // Critical Mass section (use first() since "Deadline" section also mentions "critical mass")
      const criticalMassSection = form.locator('.pulse-form-section:has-text("Critical Mass")').first()
      await expect(criticalMassSection).toBeVisible()

      // Critical mass number input
      const criticalMassInput = form.locator('input[name="critical_mass"]')
      await expect(criticalMassInput).toBeVisible()
      await expect(criticalMassInput).toHaveValue("1")

      // Deadline section
      const deadlineSection = form.locator('.pulse-form-section:has-text("Deadline")')
      await expect(deadlineSection).toBeVisible()

      // Deadline radio options
      const deadlineOptions = form.locator(".pulse-deadline-options")
      await expect(deadlineOptions).toBeVisible()

      // Submit button
      const submitBtn = form.locator('input[type="submit"][value="Start Commitment"]')
      await expect(submitBtn).toBeVisible()
      await expect(submitBtn).toHaveClass(/pulse-action-btn/)

      // Visibility hint
      const visibilityHint = form.locator(".pulse-visibility-hint")
      await expect(visibilityHint).toBeVisible()
    })

    test("commitment form shows breadcrumb navigation", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/commit`)
      await page.waitForLoadState("domcontentloaded")

      // Check breadcrumb
      const breadcrumb = page.locator("nav.pulse-breadcrumb")
      await expect(breadcrumb).toBeVisible()
      await expect(breadcrumb).toContainText("New Commitment")
    })

    test("commitment has close at critical mass option", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/commit`)
      await page.waitForLoadState("domcontentloaded")

      // Check for close at critical mass radio option (unique to commitments)
      const closeAtCriticalMassRadio = page.locator(
        'input[name="deadline_option"][value="close_at_critical_mass"]',
      )
      await expect(closeAtCriticalMassRadio).toBeVisible()

      // Click it to select
      await closeAtCriticalMassRadio.click()
      await expect(closeAtCriticalMassRadio).toBeChecked()
    })

    test("can adjust critical mass value", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/commit`)
      await page.waitForLoadState("domcontentloaded")

      const criticalMassInput = page.locator('input[name="critical_mass"]')

      // Default should be 1
      await expect(criticalMassInput).toHaveValue("1")

      // Clear and set to 5
      await criticalMassInput.fill("5")
      await expect(criticalMassInput).toHaveValue("5")

      // Should have min of 1
      await expect(criticalMassInput).toHaveAttribute("min", "1")
    })

    test("can create a commitment", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/commit`)
      await page.waitForLoadState("domcontentloaded")

      const titleText = `E2E Commitment Test ${Date.now()}`
      const descriptionText = "This is a test commitment created by e2e tests"

      // Fill the title
      await page.locator('input[name="title"]').fill(titleText)

      // Fill the description
      await page.locator('textarea[name="description"]').fill(descriptionText)

      // Set critical mass to 2
      await page.locator('input[name="critical_mass"]').fill("2")

      // Submit the form
      await page.locator('input[type="submit"][value="Start Commitment"]').click()

      // Should redirect to the created commitment
      await expect(page).toHaveURL(/\/c\//)
      await page.waitForLoadState("domcontentloaded")

      // The commitment title should be visible
      await expect(page.locator("body")).toContainText(titleText)

      // Should show Pulse styling
      await expect(page.locator(".pulse-resource-detail")).toBeVisible()
    })

    test("commitment form uses resource sidebar mode", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      await page.goto(`${baseUrl}${studioPath}/commit`)
      await page.waitForLoadState("domcontentloaded")

      // Sidebar should be in resource mode
      const sidebar = page.locator('.pulse-sidebar[data-mode="resource"]')
      await expect(sidebar).toBeVisible()
    })
  })

  test.describe("Form Styling Consistency", () => {
    test("all forms use consistent Pulse styling classes", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      const forms = [
        { path: "/note", title: "New Note" },
        { path: "/decide", title: "New Decision" },
        { path: "/commit", title: "New Commitment" },
      ]

      for (const formConfig of forms) {
        await page.goto(`${baseUrl}${studioPath}${formConfig.path}`)
        await page.waitForLoadState("domcontentloaded")

        // All should have pulse-form class
        await expect(page.locator("form.pulse-form")).toBeVisible()

        // All should have pulse-resource-detail wrapper
        await expect(page.locator(".pulse-resource-detail")).toBeVisible()

        // All should have pulse-resource-header
        await expect(page.locator(".pulse-resource-header")).toBeVisible()

        // All should have breadcrumb
        await expect(page.locator("nav.pulse-breadcrumb")).toBeVisible()

        // All should have visibility hint
        await expect(page.locator(".pulse-visibility-hint")).toBeVisible()

        // All should have resource sidebar
        await expect(page.locator('.pulse-sidebar[data-mode="resource"]')).toBeVisible()
      }
    })

    test("forms show resource type icons", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const studioPath = cachedStudioPath

      if (!studioPath) {
        test.skip()
        return
      }

      const baseUrl = buildBaseUrl()
      const forms = [
        { path: "/note", icon: "note-icon.svg", label: "Note" },
        { path: "/decide", icon: "decision-icon.svg", label: "Decision" },
        { path: "/commit", icon: "commitment-icon.svg", label: "Commitment" },
      ]

      for (const formConfig of forms) {
        await page.goto(`${baseUrl}${studioPath}${formConfig.path}`)
        await page.waitForLoadState("domcontentloaded")

        // Should have resource type label
        const typeLabel = page.locator(".pulse-resource-type-label")
        await expect(typeLabel).toBeVisible()
        await expect(typeLabel).toContainText(formConfig.label)

        // Should have resource icon
        const icon = typeLabel.locator(`img[src*="${formConfig.icon}"]`)
        await expect(icon).toBeVisible()
      }
    })
  })
})
