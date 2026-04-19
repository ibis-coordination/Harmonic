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

**Confirmation link does not require login.** The token itself is the proof of email ownership. Since initiation requires reverification (2FA), the risk of an attacker with inbox access but no Harmonic session is low.

## Constraints

- `User.email` has a unique index — new email must not belong to another user
- `OmniAuthIdentity.email` has a unique index — same constraint
- Both must be updated atomically (single transaction)
- New email must be verified before the swap (confirmation link sent to new address)
- Old email should receive a security notice ("your email was changed")
- OmniAuthIdentity.email is used as the `auth_key` for password login — after the change, the user logs in with their new email
- 2FA, password reset, and reverification all look up OmniAuthIdentity by email — must stay consistent with User.email
- Email change must be logged to SecurityAuditLog
- If user has an active Stripe customer, Stripe customer email should be updated

## Implementation

### Phase 1: Add `user_id` FK to OmniAuthIdentity

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
- `app/controllers/sessions_controller.rb:52` — 2FA check in oauth_callback (`identity.user.omni_auth_identity`)
- `app/controllers/two_factor_auth_controller.rb:208` — current_identity helper
- `app/views/users/settings.html.erb:179` — use `@settings_user.omni_auth_identity`
- `app/controllers/password_resets_controller.rb:20` — keep as-is (user isn't logged in, email is the lookup key; same applies to login)

**Bug fix:** `DataDeletionManager.delete_user!` deletes OauthIdentities but doesn't touch OmniAuthIdentity — the record survives with the original email (PII leak). Destroy it in the same transaction.

**OAuth-only users have claim-only OmniAuthIdentities** (random password, user can't log in with it). The email change flow must update these too — otherwise the email claim becomes stale and a new user could hijack the old email via identity provider signup.

**TDD order:**
1. Migration adds `user_id`, backfill matches existing records
2. `user.omni_auth_identity` association returns the right record
3. `find_or_create_omni_auth_identity!` sets `user_id`
4. Migrated lookups (sessions controller 2FA check, 2FA controller, settings view) still work
5. `DataDeletionManager.delete_user!` destroys OmniAuthIdentity

### Phase 2: Email change with verification, UI, and Stripe sync

**Migration:**
- Add `pending_email` (string, nullable), `email_confirmation_token` (string, nullable), and `email_confirmation_sent_at` (datetime, nullable) to `users` table

**Routes:**
```
PATCH /u/:handle/settings/email                → users#update_email    (initiate change)
GET   /u/:handle/settings/email/confirm/:token  → users#confirm_email   (verify new email)
```

**Security controls:**
- `update_email` requires reverification (scope: "email_change")
- Rate limit: max 3 initiation attempts per hour per user
- Confirmation token: `SecureRandom.urlsafe_base64(32)`, stored as `Digest::SHA256.hexdigest(raw_token)`, raw token sent in the email link
- Confirmation token expiry: 24 hours
- Confirmation link does not require login (token is the proof; GET modifying state is standard for email verification)

**Initiation flow (`update_email`):**
1. User enters new email in settings form
2. Validates new email: format, not taken by another User, not taken by another OmniAuthIdentity
3. Stores `pending_email`, hashed `email_confirmation_token`, `email_confirmation_sent_at`
4. Sends confirmation email to the NEW address with a verification link
5. Sends security notice to the OLD address ("an email change was requested for your account")

**Confirmation flow (`confirm_email`):**
1. Hash the token from the URL, find user by hashed token
2. Check token hasn't expired (24 hours)
3. Re-check that `pending_email` isn't now taken by another user (race condition guard)
4. In a transaction:
   - Update `User.email` to `pending_email`
   - Update `user.omni_auth_identity.email` to match
   - Clear `pending_email`, `email_confirmation_token`, `email_confirmation_sent_at`
   - Log to SecurityAuditLog
5. If `user.stripe_customer&.active?`, update Stripe customer email (outside transaction — API call; failure is non-fatal, log a warning)

**Settings UI:**
- Add email section to user settings page: read-only display of current email + form to change
- Show pending email status if a confirmation is in progress ("Check your inbox at new@email.com")

**Edge cases:**
- New email gets claimed by another user between initiation and confirmation → confirmation fails with a clear message
- User initiates a change, then initiates another before confirming → new pending_email overwrites the old one, old token becomes invalid
- User changes email while 2FA is enabled → works fine, OmniAuthIdentity.email is updated in the same transaction

**TDD order:**
1. Initiating a change stores pending_email and hashed token, sends both emails
2. Confirming with valid token swaps the email on both User and OmniAuthIdentity
3. Expired token is rejected
4. Token for already-claimed email is rejected
5. Reverification is required to initiate
6. Rate limiting rejects excessive attempts
7. Stripe customer email is updated on confirmation

## Out of Scope

- Auto-syncing email from OAuth providers on login
- Multiple email addresses per user
- Admin-initiated email changes
- Account merging when email conflicts arise
