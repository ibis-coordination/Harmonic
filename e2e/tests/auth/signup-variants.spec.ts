import { test, expect } from "@playwright/test"
import { buildBaseUrl } from "../../helpers/auth"
import {
  SIGNUP_COLLECTIVE_HANDLE,
  SIGNUP_COLLECTIVE_NAME,
  SIGNUP_PASSWORD,
  BOT_MIN_TIME_MS,
  confirmationLinkFor,
  registerViaInviteLink,
  acceptInvite,
  setupTwoFactorFromActivate,
  uniqueSignupEmail,
} from "../../helpers/signup"

/**
 * Invited-signup variants beyond the happy path (signup.spec.ts):
 * cross-device email confirmation, mid-flow abandonment, fresh-device
 * recovery, and the mobile 2FA setup layout. These pin down the
 * session-stash convergence behavior the explicit-acceptance flow relies on.
 *
 * "Another device" is another browser context — an isolated cookie jar is
 * exactly what a different device is, as far as the server can tell.
 * What can't be verified here and stays in the manual checklist
 * (test/manual/signup/): real otpauth:// handoff to an authenticator app
 * and clipboard/download behavior in real mobile browsers.
 */

test.use({ storageState: { cookies: [], origins: [] } })

test("cross-device email confirmation: original session converges back through /activate", async ({
  page,
  request,
  browser,
}) => {
  test.setTimeout(120_000)
  const email = uniqueSignupEmail("e2e-xdevice")
  const base = buildBaseUrl("app")

  // Desktop: register, accept the invite, request the confirmation email.
  await registerViaInviteLink(page, email)
  await acceptInvite(page)
  await page.locator('button:has-text("Send confirmation email")').click()
  const confirmationLink = await confirmationLinkFor(request, email)

  // Phone: open the link in a fresh context (no session at all).
  const phone = await browser.newContext({ ignoreHTTPSErrors: true })
  const phonePage = await phone.newPage()
  await phonePage.goto(confirmationLink)
  await expect(
    phonePage.locator("text=/email confirmed/i").first(),
  ).toBeVisible()
  await phone.close()

  // Desktop again: any navigation converges through /activate, where the
  // email item is now satisfied. Finishing 2FA completes activation.
  await page.goto(`${base}/`)
  await page.waitForURL(/\/activate/)
  await expect(page.locator("text=Confirmed.").first()).toBeVisible()
  await setupTwoFactorFromActivate(page)

  await page.goto(`${base}/collectives/${SIGNUP_COLLECTIVE_HANDLE}`)
  await expect(page).toHaveURL(
    new RegExp(`/collectives/${SIGNUP_COLLECTIVE_HANDLE}(?!/join)`),
  )
})

test("abandoning the confirmation page: the pending invite is remembered, no code re-entry", async ({
  page,
}) => {
  test.setTimeout(90_000)
  const email = uniqueSignupEmail("e2e-abandon")
  const base = buildBaseUrl("app")

  await registerViaInviteLink(page, email)

  // Wander off without accepting. The session-stashed pending invite routes
  // any later visit straight back to the confirmation page.
  await page.goto(`${base}/`)
  await page.waitForURL(/\/invite-required/)
  await expect(page.locator("text=You're invited to join")).toBeVisible()
  await expect(
    page.locator(`text=${SIGNUP_COLLECTIVE_NAME}`).first(),
  ).toBeVisible()

  // Accepting from the recovered page works normally.
  await acceptInvite(page)
  await expect(
    page.locator("text=You have accepted your invite"),
  ).toBeVisible()
})

test("fresh device with no session: not silently a member; invite code is asked for", async ({
  page,
  browser,
}) => {
  test.setTimeout(90_000)
  const email = uniqueSignupEmail("e2e-freshdev")
  const base = buildBaseUrl("app")

  // Register but do NOT accept — the account exists, no tenant membership.
  await registerViaInviteLink(page, email)

  // Log in from a clean context (different device, no session stash).
  const fresh = await browser.newContext({ ignoreHTTPSErrors: true })
  const freshPage = await fresh.newPage()
  await freshPage.goto(`${base}/login`)
  await freshPage.locator('input[name="auth_key"]').fill(email)
  await freshPage.locator('input[name="password"]').fill(SIGNUP_PASSWORD)
  // The login POST is bot-protected the same way as registration.
  if (await freshPage.locator(".cf-turnstile").count()) {
    await expect(
      freshPage.locator('input[name="cf_turnstile_response"]'),
    ).toHaveValue(/.+/, { timeout: 15_000 })
  }
  await freshPage.waitForTimeout(BOT_MIN_TIME_MS)
  await freshPage
    .locator('input[type="submit"][value="Log in"], button:has-text("Log in")')
    .first()
    .click()

  // No membership, no invite in this session → the explainer with the
  // code-entry form, not silent tenant access.
  await freshPage.waitForURL(/\/invite-required/)
  await expect(
    freshPage.locator('form[action="/invite-required"] input[name="code"]'),
  ).toBeVisible()
  await fresh.close()
})

test.describe("mobile viewport", () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test("2FA setup leads with the deep link and copyable key; QR code is hidden", async ({
    page,
  }) => {
    test.setTimeout(120_000)
    const email = uniqueSignupEmail("e2e-mobile2fa")
    const base = buildBaseUrl("app")

    await registerViaInviteLink(page, email)
    await acceptInvite(page)
    await page.locator('a:has-text("Set up 2FA")').click()
    await page.waitForURL(/\/settings\/two-factor/)

    // Same-device paths are primary on a small screen. The desktop block
    // contains the same partial behind a disclosure, so scope to the
    // mobile block to assert what's actually visible.
    const mobileBlock = page.locator(".pulse-2fa-setup-mobile")
    await expect(mobileBlock).toBeVisible()
    const deepLink = mobileBlock.locator(
      'a:has-text("Open in authenticator app")',
    )
    await expect(deepLink).toBeVisible()
    await expect(deepLink).toHaveAttribute("href", /^otpauth:\/\//)
    await expect(
      mobileBlock.locator('button:has-text("Copy key")'),
    ).toBeVisible()
    // The QR code only makes sense cross-device; it's hidden on mobile.
    await expect(page.locator(".two-factor-qr-code")).toBeHidden()

    // Setup completes; Copy is the primary action on the recovery codes.
    await page
      .locator('input[name="code"]')
      .fill(process.env.DEV_2FA_BYPASS_CODE || "333333")
    await page.locator('input[type="submit"]').click()
    await expect(page.locator("text=Save Your Recovery Codes")).toBeVisible()
    await expect(
      page.locator('button.pulse-action-btn:has-text("Copy codes")'),
    ).toBeVisible()
  })
})
