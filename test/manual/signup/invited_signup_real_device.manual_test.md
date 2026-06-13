---
passing: null
last_verified: null
verified_by: null
---

# Test: Invited Signup — Real-Device Checks

Verifies the parts of mobile signup that automated tests cannot reach:
OS-level protocol handoff and real mobile-browser clipboard/download
behavior. Everything else about the signup flow is automated —
the happy path in `e2e/tests/auth/signup.spec.ts`, and the cross-device /
abandonment / fresh-device / mobile-layout variants in
`e2e/tests/auth/signup-variants.spec.ts` (browser contexts emulate devices;
viewport emulation covers the responsive layout).

What emulation can't verify: tapping an `otpauth://` link is an OS protocol
handoff to an installed authenticator app, and clipboard / `download`
support varies across real mobile browsers (iOS Safari especially) in ways
desktop Chromium with a narrow viewport does not reproduce.

## Prerequisites

- A real phone (test iOS Safari at minimum; Android Chrome if available)
  with an authenticator app installed (Google Authenticator, 1Password, etc.)
- An unexpired invite link for a standard (non-main) collective on a tenant
  with `require_2fa` enabled
- Access to the inbox for a fresh email address

## Steps

1. On the phone, open the invite link, register a new account, and accept
   the invite
2. On the activation checklist, tap "Set up 2FA"
3. Tap **"Open in authenticator app"**
   - Verify the authenticator opens with the account pre-filled (issuer and
     email visible)
   - If the phone shows a handler-picker, verify choosing the authenticator
     completes enrollment
4. Go back, tap **"Copy key"**, and paste into a notes app
   - Verify the pasted value is the raw secret with no spaces
   - Verify manually adding an account in the authenticator with the pasted
     key yields working codes
5. Complete setup with a real 6-digit code from the authenticator
6. On the recovery codes screen:
   - Tap **"Copy codes"** and verify all codes land on the clipboard
   - Tap **"Download"** and note whether the browser saves a file (known to
     be unreliable on mobile; Copy is the primary affordance)
7. Log out, log back in, and verify the TOTP prompt accepts the
   authenticator's code

## Expected Results

- The `otpauth://` deep link enrolls the account without scanning or typing
- "Copy key" / "Copy codes" work in the real mobile browser
- A real TOTP code (not just the dev bypass) round-trips through setup and
  a subsequent login
