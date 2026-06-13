---
passing: null
last_verified: null
verified_by: null
---

# Test: Invited Signup — Cross-Device and Abandonment Variants

Verifies the invite-link signup flow converges on the explicit acceptance
page in the variants that automated tests can't exercise well: confirming
email on a second device, abandoning mid-flow, and mobile 2FA setup. The
straight-through happy path is covered by `e2e/tests/auth/signup.spec.ts`.

## Prerequisites

- A tenant with `require_invite`, `require_verified_email`, and `require_2fa`
  enabled (the defaults)
- An unexpired invite link for a standard (non-main) collective
- Two devices or browser profiles ("desktop" and "phone")
- An authenticator app on the phone
- Access to the inbox for a fresh email address

## Steps

### Part 1: Cross-device email confirmation

1. On the **desktop** browser, open the invite link while logged out
2. Register a new account (email/password)
3. Land on the invite confirmation page — verify it names the collective and
   shows its avatar — and click "Accept and join"
4. On the activation checklist, click "Send confirmation email"
5. Open the confirmation link **on the phone** (different device, no session)
6. Verify the phone shows the "Email confirmed" page
7. Back on the **desktop**, navigate anywhere (or refresh)
8. Verify you are routed through `/activate` with the email item checked,
   not stranded — and that completing 2FA finishes activation and returns
   you to the collective

### Part 2: Abandon before accepting

1. In a fresh browser profile, open the invite link and register another
   new account
2. On the invite confirmation page, do NOT accept — close the tab
3. Reopen the app root (`/`) in the same browser profile
4. Verify you land back on the invite confirmation page for the same
   collective (the pending invite is remembered in the session; no code
   re-entry needed)
5. Accept, complete activation, and verify you end up a member of the
   collective

### Part 3: Fresh device, no session

1. After Part 2's account exists but using a different browser profile
   (no cookies), log in with that account's email/password
2. Verify you are NOT silently inside the tenant: if the account never
   accepted an invite, you land on `/invite-required` and can re-enter the
   invite code manually; if it did accept, you land in the app normally

### Part 4: Mobile 2FA setup

1. On the **phone**, register a new account via the invite link and accept
   the invite
2. On the activation checklist, tap "Set up 2FA"
3. Verify the QR code is NOT shown on the small screen; instead there is an
   "Open in authenticator app" button and a copyable setup key
4. Tap "Open in authenticator app" — verify the authenticator opens with the
   account pre-filled (or, if no handler is registered, use "Copy key" and
   paste it into the authenticator manually)
5. Enter the 6-digit code and verify setup completes
6. On the recovery codes screen, tap "Copy codes" and verify the codes land
   on the clipboard (Copy is the primary button; Download may not work in
   mobile browsers)

## Expected Results

- No variant strands the user: every path leads back to either the invite
  confirmation page or the activation checklist
- Tenant and collective membership are created only by the explicit
  "Accept and join" action, never by merely logging in or following links
- The collective invite is accepted exactly once; revisiting the
  confirmation page after acceptance bounces to the app root
- Mobile 2FA setup is completable without scanning a QR code
