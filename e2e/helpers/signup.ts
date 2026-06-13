import { Page, APIRequestContext, expect } from "@playwright/test"
import { buildBaseUrl } from "./auth"

/**
 * Shared steps for the invited-signup specs (signup.spec.ts and
 * signup-variants.spec.ts). Prereqs are seeded by `rake e2e:setup`:
 * the "e2e-signup" collective and a reusable invite code.
 */

export const INVITE_CODE =
  process.env.E2E_SIGNUP_INVITE_CODE || "e2e-signup-invite-code"
export const SIGNUP_COLLECTIVE_HANDLE = "e2e-signup"
export const SIGNUP_COLLECTIVE_NAME = "E2E Signup Collective"
export const MAILCATCHER_URL =
  process.env.E2E_MAILCATCHER_URL || "http://localhost:1080"
export const SIGNUP_PASSWORD = "e2e-signup-password-14chars"
// BotProtection rejects form submits faster than MIN_FORM_TIME_SECONDS (1s)
export const BOT_MIN_TIME_MS = 1500

export function uniqueSignupEmail(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1e6)}@example.com`
}

/**
 * Polls mailcatcher for the confirmation email sent to `email` and returns
 * the confirm-email link. The confirmation mailer renders an HTML part only.
 */
export async function confirmationLinkFor(
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

/**
 * Follows the invite link logged-out and registers a brand-new account.
 * Ends on the invite confirmation page (/invite-required?code=...).
 */
export async function registerViaInviteLink(
  page: Page,
  email: string,
  name = "E2E Signup User",
): Promise<void> {
  const base = buildBaseUrl("app")
  await page.goto(
    `${base}/collectives/${SIGNUP_COLLECTIVE_HANDLE}/join?code=${INVITE_CODE}`,
  )
  await page.locator('input[name="auth_key"]').waitFor({ state: "visible" })

  await page.locator('a:has-text("Create one")').click()
  await page.locator("#email-field").fill(email)
  await page.locator("#name-field").fill(name)
  await page.locator("#password-field").fill(SIGNUP_PASSWORD)
  await page.locator("#password-confirmation-field").fill(SIGNUP_PASSWORD)
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

  await page.waitForURL(/\/invite-required/)
  await expect(page.locator("text=You're invited to join")).toBeVisible()
}

/**
 * Clicks "Accept and join" on the invite confirmation page. The activation
 * gate intercepts the post-acceptance redirect, landing on /activate.
 */
export async function acceptInvite(page: Page): Promise<void> {
  await page.waitForTimeout(BOT_MIN_TIME_MS)
  await page.locator('button:has-text("Accept and join")').click()
  await page.waitForURL(/\/activate/)
}

/**
 * Completes 2FA setup from /activate using the dev-only bypass code, through
 * the recovery-codes page. Ends wherever the Continue link lands.
 */
export async function setupTwoFactorFromActivate(page: Page): Promise<void> {
  await page.locator('a:has-text("Set up 2FA")').click()
  await page
    .locator('input[name="code"]')
    .fill(process.env.DEV_2FA_BYPASS_CODE || "333333")
  await page.locator('input[type="submit"]').click()
  await expect(page.locator("text=Save Your Recovery Codes")).toBeVisible()
  await page.locator('a:has-text("Continue")').click()
}
