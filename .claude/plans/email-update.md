# Email Update Feature

## Problem

Users have no way to change their email address. This affects:
- Identity provider users (email/password login) who can never update their email
- OAuth users whose provider email has changed (login still works via uid matching, but the Harmonic email becomes stale)
- All users: stale emails break notification delivery, password resets, Stripe billing communications, and 2FA lookups

## Design Decisions

**No auto-sync from OAuth providers.** If a user manually changes their email in Harmonic, the app should respect that. Auto-syncing on OAuth login would silently overwrite intentional changes. Users who want their email updated can do it themselves in settings.

**No multi-email model.** A separate EmailAddress table with primary/secondary support solves a problem we don't have. One email column on User is sufficient. Migrating to a multi-email model later is straightforward if needed.

**Add `user_id` FK to OmniAuthIdentity.** Currently the only link between User and OmniAuthIdentity is matching emails. If an email update partially fails, the identity record becomes orphaned — no way to find it without the correct email. Adding an explicit `user_id` foreign key ensures the association survives regardless of email state, and lets lookups use `user.omni_auth_identity` instead of `OmniAuthIdentity.find_by(email: user.email)`.

**Confirmation link does not require login.** The token itself is the proof of email ownership (same pattern as password reset). Since initiation requires reverification (2FA), the risk of an attacker with inbox access but no Harmonic session is low.

## Constraints

- `User.email` has a unique index — new email must not belong to another user
- `OmniAuthIdentity.email` has a unique index — same constraint
- Both must be updated atomically (single transaction)
- New email must be verified before the swap (confirmation link sent to new address)
- Old email should receive a security notice with specific remediation steps based on the user's auth methods
- OmniAuthIdentity.email is used as the `auth_key` for password login — after the change, the user logs in with their new email
- Email change must be logged to SecurityAuditLog
- If user has an active Stripe customer, Stripe customer email should be updated (non-fatal)
- Token comparison must use constant-time comparison (`ActiveSupport::SecurityUtils.secure_compare`)

## Implementation

### Phase 1: Add `user_id` FK to OmniAuthIdentity (committed)

**Migration:**
1. Add `user_id` (uuid, nullable FK to users) to `omni_auth_identities`
2. Backfill: `UPDATE omni_auth_identities SET user_id = users.id FROM users WHERE users.email = omni_auth_identities.email`
3. Add unique index on `user_id` (one identity per user; NULLs allowed for registration-in-progress)

`user_id` is nullable because OmniAuth's identity registration flow creates the record before a User exists. The `find_or_create_omni_auth_identity!` method adopts these orphaned records by matching on email and backfilling `user_id`.

**Model changes:**
- `User`: add `has_one :omni_auth_identity, dependent: :destroy`; remove the existing `omni_auth_identity` method that queries by email
- `OmniAuthIdentity`: add `belongs_to :user, optional: true`
- `User#find_or_create_omni_auth_identity!`: check association first, then adopt orphaned record by email, then create new

**Migrate lookups** from `OmniAuthIdentity.find_by(email: user.email)` to `user.omni_auth_identity`:
- `app/models/user.rb` — the method being replaced by the association
- `app/controllers/sessions_controller.rb:52` — 2FA check in oauth_callback
- `app/controllers/two_factor_auth_controller.rb:208` — current_identity helper
- `app/views/users/settings.html.erb:179` — use `@settings_user.omni_auth_identity`
- Password reset and login keep email-based lookup (user isn't authenticated)

**Bug fix:** `DataDeletionManager.delete_user!` now destroys OmniAuthIdentity (was a PII leak).

### Phase 2: Email change with verification, UI, and Stripe sync

**Migration:**
- Add `pending_email` (string, nullable), `email_confirmation_token` (string, nullable), and `email_confirmation_sent_at` (datetime, nullable) to `users` table

**Routes:**
```
PATCH  /u/:handle/settings/email                → users#update_email       (initiate change)
DELETE /u/:handle/settings/email                → users#cancel_email_change (cancel pending)
GET    /u/:handle/settings/email/confirm/:token → users#confirm_email      (verify new email)
```

**Security controls:**
- `update_email` requires reverification (scope: "email_change")
- Confirmation token: `SecureRandom.urlsafe_base64(32)`, stored as `Digest::SHA256.hexdigest(raw_token)`
- Token comparison uses `ActiveSupport::SecurityUtils.secure_compare` (constant-time)
- Confirmation token expiry: 24 hours
- Confirmation link does not require login (exempted from `validate_unauthenticated_access`)
- Rack::Attack throttle: 5 email change requests per hour per IP
- `confirm_email` exempted from billing gate

**Initiation flow (`update_email`):**
1. User enters new email in settings form
2. Validates: format, not current email, not taken by another User or OmniAuthIdentity
3. Stores `pending_email`, hashed `email_confirmation_token`, `email_confirmation_sent_at`
4. Sends confirmation email to the NEW address with a verification link
5. Sends security notice to the OLD address (with auth-method-specific remediation steps)

**Confirmation flow (`confirm_email`):**
1. Guard: if `pending_email` is blank, return early (handles double-click idempotency)
2. Hash the token from the URL, compare against stored hash with `secure_compare`
3. Check token hasn't expired (24 hours)
4. In a transaction: re-check email not claimed, update `User.email` and `OmniAuthIdentity.email`, clear pending fields
5. If transaction rolled back (email claimed), clear stale pending state separately
6. Log to SecurityAuditLog
7. Sync Stripe customer email if applicable (outside transaction, non-fatal)

**Cancel flow (`cancel_email_change`):**
1. Clears `pending_email`, `email_confirmation_token`, `email_confirmation_sent_at`
2. Old confirmation link becomes invalid (pending_email blank guard catches it)

**Settings UI:**
- Email section shows current email and form to change
- When a change is pending: shows pending email with expiry notice, "Resend Confirmation" button, "Cancel" button, and "Change to a Different Email" form
- Re-initiating a change overwrites the previous pending email and invalidates the old token

**Reverification replay mechanism (general-purpose):**
- When a non-GET request triggers reverification, the concern stashes the method, path, and params in the session
- After TOTP verification, redirects to `GET /reverify/replay` which renders an auto-submit form
- The form uses a global CSRF token (not per-form) to avoid token mismatches
- Auto-submit via Stimulus `auto-submit` controller (not inline JS, to comply with CSP)

**Related fixes:**
- Logout now uses `reset_session` instead of `session.delete(:user_id)` (was leaking reverification timestamps and other session state across logins)
- Mailcatcher added to `frontend` network in docker-compose (was on `internal`-only `backend` network, blocking browser access)

## Out of Scope

- Auto-syncing email from OAuth providers on login
- Multiple email addresses per user
- Admin-initiated email changes
- Account merging when email conflicts arise
