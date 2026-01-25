import { test, expect } from "../../fixtures/test-fixtures"
import { buildBaseUrl } from "../../helpers/auth"
import path from "path"

test.describe("Profile Image Upload", () => {
  test.describe("Image Cropper", () => {
    test("can open file picker from profile image", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      // Navigate to user settings page
      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Profile image container should be visible
      const imageContainer = page.locator('[data-image-cropper-target="container"]')
      await expect(imageContainer).toBeVisible()

      // Set up file chooser listener before clicking
      const fileChooserPromise = page.waitForEvent("filechooser")

      // Click on profile image to open file picker
      await imageContainer.click()

      // File chooser should open
      const fileChooser = await fileChooserPromise
      expect(fileChooser).toBeTruthy()
    })

    test("cropper modal appears after selecting image", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Set up file chooser listener
      const fileChooserPromise = page.waitForEvent("filechooser")

      // Click profile image
      await page.locator('[data-image-cropper-target="container"]').click()

      // Select a test image file
      const fileChooser = await fileChooserPromise
      const testImagePath = path.resolve(
        __dirname,
        "../../../public/placeholder.png",
      )
      await fileChooser.setFiles(testImagePath)

      // Cropper modal should appear
      const modal = page.locator('[data-image-cropper-target="modal"]')
      await expect(modal).toBeVisible()

      // Modal should have "Crop Image" heading
      await expect(modal.locator("h3")).toContainText("Crop Image")

      // Modal should have "Save Image" button
      const saveButton = modal.locator('button:has-text("Save Image")')
      await expect(saveButton).toBeVisible()

      // Modal should have close button
      const closeButton = modal.locator('button:has-text("×")')
      await expect(closeButton).toBeVisible()
    })

    test("can cancel cropper modal", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Open file chooser and select image
      const fileChooserPromise = page.waitForEvent("filechooser")
      await page.locator('[data-image-cropper-target="container"]').click()
      const fileChooser = await fileChooserPromise
      await fileChooser.setFiles(
        path.resolve(__dirname, "../../../public/placeholder.png"),
      )

      // Wait for modal to appear
      const modal = page.locator('[data-image-cropper-target="modal"]')
      await expect(modal).toBeVisible()

      // Click close button
      await modal.locator('button:has-text("×")').click()

      // Modal should be hidden
      await expect(modal).toBeHidden()
    })

    test("can cancel cropper modal with Escape key", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Open file chooser and select image
      const fileChooserPromise = page.waitForEvent("filechooser")
      await page.locator('[data-image-cropper-target="container"]').click()
      const fileChooser = await fileChooserPromise
      await fileChooser.setFiles(
        path.resolve(__dirname, "../../../public/placeholder.png"),
      )

      // Wait for modal to appear
      const modal = page.locator('[data-image-cropper-target="modal"]')
      await expect(modal).toBeVisible()

      // Press Escape key
      await page.keyboard.press("Escape")

      // Modal should be hidden
      await expect(modal).toBeHidden()
    })

    test("can upload and save cropped image", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Get the current image URL to compare later
      const imageBefore = await page
        .locator('[data-image-cropper-target="image"]')
        .getAttribute("src")

      // Open file chooser and select image
      const fileChooserPromise = page.waitForEvent("filechooser")
      await page.locator('[data-image-cropper-target="container"]').click()
      const fileChooser = await fileChooserPromise
      await fileChooser.setFiles(
        path.resolve(__dirname, "../../../public/placeholder.png"),
      )

      // Wait for modal to appear
      const modal = page.locator('[data-image-cropper-target="modal"]')
      await expect(modal).toBeVisible()

      // Set up navigation listener to detect form submission
      const responsePromise = page.waitForResponse(
        (response) =>
          response.url().includes("/image") && response.status() < 400,
      )

      // Click "Save Image" button
      await modal.locator('button:has-text("Save Image")').click()

      // Wait for response (form submission)
      await responsePromise

      // Modal should close after save
      await expect(modal).toBeHidden()

      // Page should still be on settings (redirect back after save)
      await expect(page).toHaveURL(/\/settings/)
    })

    test("image cropper controller is registered", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Verify Stimulus controller is connected
      const controllerElement = page.locator('[data-controller="image-cropper"]')
      await expect(controllerElement).toBeVisible()

      // Verify all required targets exist
      await expect(
        page.locator('[data-image-cropper-target="container"]'),
      ).toBeVisible()
      await expect(
        page.locator('[data-image-cropper-target="image"]'),
      ).toBeVisible()
      await expect(
        page.locator('[data-image-cropper-target="input"]'),
      ).toBeAttached()
      await expect(
        page.locator('[data-image-cropper-target="modal"]'),
      ).toBeAttached()
      await expect(
        page.locator('[data-image-cropper-target="form"]'),
      ).toBeAttached()
      await expect(
        page.locator('[data-image-cropper-target="croppedData"]'),
      ).toBeAttached()
    })

    test("profile image form is not nested inside another form", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // The image cropper form should exist as a proper form element
      const cropperForm = page.locator('[data-image-cropper-target="form"]')
      await expect(cropperForm).toBeAttached()

      // Verify it's actually a form element (not stripped by browser due to nesting)
      const tagName = await cropperForm.evaluate((el) => el.tagName.toLowerCase())
      expect(tagName).toBe("form")

      // Verify the form has the correct action
      const action = await cropperForm.getAttribute("action")
      expect(action).toContain("/image")
    })
  })

  test.describe("Settings Page Structure", () => {
    test("settings page uses minimal sidebar", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Should have minimal sidebar
      const sidebar = page.locator('.pulse-sidebar[data-mode="minimal"]')
      await expect(sidebar).toBeVisible()

      // Should have home link
      const homeLink = sidebar.locator('a:has-text("Home")')
      await expect(homeLink).toBeVisible()
    })

    test("settings page has profile section", async ({ authenticatedPage }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Profile accordion should exist (use accordion-specific selector)
      await expect(
        page.locator(".pulse-accordion-title:has-text('Profile')"),
      ).toBeVisible()

      // Profile image section should exist
      await expect(page.locator('text="Profile Image"')).toBeVisible()

      // Display name field should exist
      await expect(page.locator('input[name="name"]')).toBeVisible()

      // Handle field should exist
      await expect(page.locator('input[name="new_handle"]')).toBeVisible()
    })

    test("breadcrumb shows Users as text not link", async ({
      authenticatedPage,
    }) => {
      const page = authenticatedPage
      const baseUrl = buildBaseUrl()

      await page.goto(`${baseUrl}/u/e2e-test-user/settings`)
      await page.waitForLoadState("domcontentloaded")

      // Breadcrumb should show "Users" text
      const breadcrumb = page.locator("nav.pulse-breadcrumb")
      await expect(breadcrumb).toContainText("Users")

      // "Users" should NOT be a link (no href="/users")
      const usersLink = breadcrumb.locator('a[href="/users"]')
      await expect(usersLink).toHaveCount(0)
    })
  })
})
