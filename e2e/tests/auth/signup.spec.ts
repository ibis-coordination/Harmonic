import { test, expect, APIRequestContext } from "@playwright/test"
import { buildBaseUrl } from "../../helpers/auth"

/**
 * Invited-signup happy path, end to end:
 *
 *   invite link → register (email/password) → explicit invite acceptance →
 *   activation checklist → email confirmation (via mailcatcher) →
 *   2FA setup → member of the collective.
 *
 * Prereqs (seeded by `rake e2e:setup`): the "e2e-signup" collective and a
 * reusable invite code. A fresh user is registered on every run.
 *
 * The 2FA confirm step uses the dev-only bypass code (DEV_2FA_BYPASS_CODE)
 * instead of computing a real TOTP — the TOTP math is covered by unit tests;
 * this spec is about the flow.
 */

// The chromium project pre-authenticates as the shared test user via
// storageState; signup must start logged out with a clean cookie jar.
test.use({ storageState: { cookies: [], origins: [] } })

const INVITE_CODE =
  process.env.E2E_SIGNUP_INVITE_CODE || "e2e-signup-invite-code"
const SIGNUP_COLLECTIVE_HANDLE = "e2e-signup"
const MAILCATCHER_URL =
  process.env.E2E_MAILCATCHER_URL || "http://localhost:1080"
// BotProtection rejects form submits faster than MIN_FORM_TIME_SECONDS (1s)
const BOT_MIN_TIME_MS = 1500

async function confirmationLinkFor(
  request: APIRequestContext,
  email: string,
): Promise<string> {
  for (let attempt = 0; attempt < 30; attempt++) {
    const res = await request.get(`${MAILCATCHER_URL}/messages`)
    const messages = (await res.json()) as Array<{
      id: number
      recipients: string[]
    }>
    const message = [...messages]
      .reverse()
      .find((m) => m.recipients?.some((r) => r.includes(email)))
    if (message) {
      // The confirmation mailer renders an HTML part only.
      const body = await (
        await request.get(`${MAILCATCHER_URL}/messages/${message.id}.html`)
      ).text()
      const match = body.match(/https?:\/\/[^"'\s<]*\/confirm-email\/[^"'\s<]+/)
      if (match) return match[0]
    }
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  throw new Error(`No confirmation email for ${email} arrived in mailcatcher`)
}

test("invited signup: register, accept invite, confirm email, set up 2FA, land in the collective", async ({
  page,
  request,
}) => {
  // Generous budget: this walks five separate flows with bot-protection
  // pauses and a mailcatcher poll in the middle.
  test.setTimeout(120_000)
  const email = `e2e-signup-${Date.now()}@example.com`
  const password = "e2e-signup-password-14chars"
  const base = buildBaseUrl("app")

  // 1. Unauthenticated invite link → bounced to login; the invite code
  //    travels via the shared-domain cookie.
  await page.goto(
    `${base}/collectives/${SIGNUP_COLLECTIVE_HANDLE}/join?code=${INVITE_CODE}`,
  )
  await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })

  // 2. Register a brand-new account.
  await page.locator('a:has-text("Create one")').click()
  await page.locator("#email-field").fill(email)
  await page.locator("#name-field").fill("E2E Signup User")
  await page.locator("#password-field").fill(password)
  await page.locator("#password-confirmation-field").fill(password)
  await expect(page.locator("#submit-button")).toBeEnabled()
  // When Turnstile is configured (the dev env uses Cloudflare's test keys),
  // its async widget must finish injecting the response token before submit,
  // or the bot-protection middleware bounces the registration to /login.
  if (await page.locator(".cf-turnstile").count()) {
    await expect(
      page.locator('input[name="cf_turnstile_response"]'),
    ).toHaveValue(/.+/, { timeout: 15_000 })
  }
  await page.waitForTimeout(BOT_MIN_TIME_MS)
  await page.locator("#submit-button").click()

  // 3. The callback routes new users to the invite confirmation page —
  //    joining is explicit, nothing was joined during login.
  await page.waitForURL(/\/invite-required/)
  await expect(page.locator("text=You're invited to join")).toBeVisible()
  await page.waitForTimeout(BOT_MIN_TIME_MS)
  await page.locator('button:has-text("Accept and join")').click()

  // 4. Acceptance joins tenant + collective; the activation gate intercepts
  //    the redirect to the collective and shows the checklist.
  await page.waitForURL(/\/activate/)
  await expect(
    page.locator("text=You have accepted your invite"),
  ).toBeVisible()

  // 5. Email confirmation round-trip through mailcatcher.
  await page.locator('button:has-text("Send confirmation email")').click()
  const confirmationLink = await confirmationLinkFor(request, email)
  await page.goto(confirmationLink)
  await expect(page.locator("text=/email confirmed/i").first()).toBeVisible()

  // 6. 2FA setup. The confirm step accepts the dev bypass code.
  await page.goto(`${base}/activate`)
  await page.locator('a:has-text("Set up 2FA")').click()
  await page
    .locator('input[name="code"]')
    .fill(process.env.DEV_2FA_BYPASS_CODE || "333333")
  await page.locator('input[type="submit"]').click()

  // Recovery codes are shown once; Copy is the primary action.
  await expect(page.locator("text=Save Your Recovery Codes")).toBeVisible()
  await page.locator('a:has-text("Continue")').click()

  // 7. Fully activated member: the collective renders instead of bouncing
  //    to its join page.
  await page.goto(`${base}/collectives/${SIGNUP_COLLECTIVE_HANDLE}`)
  await expect(page).toHaveURL(
    new RegExp(`/collectives/${SIGNUP_COLLECTIVE_HANDLE}(?!/join)`),
  )
  await expect(page.locator("text=E2E Signup Collective").first()).toBeVisible()
})
