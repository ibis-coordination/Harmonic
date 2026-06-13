import { test, expect } from "@playwright/test"
import { buildBaseUrl } from "../../helpers/auth"
import {
  SIGNUP_COLLECTIVE_HANDLE,
  SIGNUP_COLLECTIVE_NAME,
  confirmationLinkFor,
  registerViaInviteLink,
  acceptInvite,
  setupTwoFactorFromActivate,
  uniqueSignupEmail,
} from "../../helpers/signup"

/**
 * Invited-signup happy path, end to end:
 *
 *   invite link → register (email/password) → explicit invite acceptance →
 *   activation checklist → email confirmation (via mailcatcher) →
 *   2FA setup → member of the collective.
 *
 * The 2FA confirm step uses the dev-only bypass code (DEV_2FA_BYPASS_CODE)
 * instead of computing a real TOTP — the TOTP math is covered by unit tests;
 * this spec is about the flow. Cross-device, abandonment, and mobile-layout
 * variants live in signup-variants.spec.ts.
 */

// The chromium project pre-authenticates as the shared test user via
// storageState; signup must start logged out with a clean cookie jar.
test.use({ storageState: { cookies: [], origins: [] } })

test("invited signup: register, accept invite, confirm email, set up 2FA, land in the collective", async ({
  page,
  request,
}) => {
  // Generous budget: this walks five separate flows with bot-protection
  // pauses and a mailcatcher poll in the middle.
  test.setTimeout(120_000)
  const email = uniqueSignupEmail("e2e-signup")
  const base = buildBaseUrl("app")

  // 1-3. Invite link → registration → invite confirmation page. Joining is
  //      explicit: nothing was joined during login.
  await registerViaInviteLink(page, email)
  await acceptInvite(page)

  // 4. Acceptance joined tenant + collective; the activation gate intercepted
  //    the redirect to the collective and shows the checklist.
  await expect(
    page.locator("text=You have accepted your invite"),
  ).toBeVisible()

  // 5. Email confirmation round-trip through mailcatcher.
  await page.locator('button:has-text("Send confirmation email")').click()
  const confirmationLink = await confirmationLinkFor(request, email)
  await page.goto(confirmationLink)
  await expect(page.locator("text=/email confirmed/i").first()).toBeVisible()

  // 6. 2FA setup.
  await page.goto(`${base}/activate`)
  await setupTwoFactorFromActivate(page)

  // 7. Fully activated member: the collective renders instead of bouncing
  //    to its join page.
  await page.goto(`${base}/collectives/${SIGNUP_COLLECTIVE_HANDLE}`)
  await expect(page).toHaveURL(
    new RegExp(`/collectives/${SIGNUP_COLLECTIVE_HANDLE}(?!/join)`),
  )
  await expect(
    page.locator(`text=${SIGNUP_COLLECTIVE_NAME}`).first(),
  ).toBeVisible()
})
