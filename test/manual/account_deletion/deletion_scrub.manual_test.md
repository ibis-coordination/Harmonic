---
passing: true
last_verified: 2026-07-31
verified_by: Claude (Playwright browser + rails runner, dev env with Stripe sandbox)
---

# Test: Account Deletion (end to end)

Walks the full two-phase deletion causal chain in a development environment
with the Stripe sandbox: build a departing user with every kind of footprint,
exercise the self-serve request/restore flows (global and per-subdomain), let
the scrub job run the irreversible phase, and verify each observable
consequence — access termination, "Deleted User" rendering, audit-chain
scrubbing, billing cleanup, emails, and idempotent re-run. Run before merging
changes to `AccountDeletionService`, `AccountDeletionScrubJob`,
`DataDeletionManager#delete_user!`, or the `/account/deletion` flows.

## Prerequisites

- Dev environment running (`./scripts/start.sh`)
- Stripe sandbox key configured (`STRIPE_API_KEY` — verify with
  `docker compose exec web printenv STRIPE_API_KEY | head -c 8`)
- Mailcatcher for email checks: <http://localhost:1080> (or
  `curl -s http://localhost:1080/messages`)
- Two tenants the departing user can join (the per-subdomain test needs a
  second subdomain)
- A tenant + collective with at least one existing member you can act as
  (the "viewer") besides the departing user
- Two browser contexts (e.g. a normal and a private window), or one browser
  plus the markdown UI via curl

## Setup: build the departing user's footprint

1. Rails console (`./scripts/rails-c.sh`):

   ```ruby
   tenant = Tenant.find_by!(subdomain: "app")   # adjust to your tenant
   tenant2 = Tenant.find_by!(subdomain: "<second subdomain>")
   viewer = User.find_by!(email: "<your dev login email>")
   dave = User.create!(email: "dave-#{SecureRandom.hex(3)}@example.com",
                       name: "Deleting Dave", user_type: "human")
   # Password login identity (2FA enabled — activation requires it; the
   # /login/verify-2fa step accepts the dev bypass code)
   identity = OmniAuthIdentity.find_or_initialize_by(email: dave.email)
   identity.name = dave.name
   identity.password = identity.password_confirmation = "dave-test-password-14chars"
   identity.otp_secret = ROTP::Base32.random
   identity.otp_enabled = true
   identity.otp_enabled_at = Time.current
   identity.email_confirmed_at = Time.current
   identity.save!
   tenant.add_user!(dave)
   tenant2.add_user!(dave)
   collective = tenant.main_collective            # or any shared collective
   collective.add_user!(dave)
   collective.add_user!(viewer) unless collective.users.include?(viewer)
   # Trustee authorization in each direction
   TrusteeGrant.create!(tenant: tenant, granting_user: dave, trustee_user: viewer)
   TrusteeGrant.create!(tenant: tenant, granting_user: viewer, trustee_user: dave)
   # Notification forwarder (user-owned automation rule)
   AutomationRule.create!(tenant: tenant, user: dave, created_by: dave,
     name: "Dave's forwarder", trigger_type: "event",
     trigger_config: { "event_types" => ["notifications.delivered"] },
     actions: { "webhook_url" => "https://example.com/dave-hook" }, enabled: true)
   # AI agent principaled by Dave
   Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
   agent = User.create!(email: "#{SecureRandom.uuid}@not-a-real-email.com",
     name: "Dave's Agent", user_type: "ai_agent", parent_id: dave.id,
     agent_configuration: { "mode" => "internal" })
   Tenant.clear_thread_scope
   # Creating the agent does NOT give it tenant presence — without this the
   # agent-archival checks below are vacuously true.
   tenant.add_user!(agent)
   # Stripe sandbox customer
   cus = Stripe::Customer.create({ email: dave.email, name: "Deleting Dave (dev test)" })
   StripeCustomer.create!(billable: dave, stripe_id: cus.id, active: true)
   puts "dave=#{dave.id} handle=#{dave.tenant_users.first.handle} stripe=#{cus.id}"
   ```

   Record the printed handle and Stripe id.

2. Browser context A: log in as Dave (`/login` with his email + the password
   above; pass `/login/verify-2fa` with the dev bypass code `333333`), then:
   - Create a note titled "Dave's note" in the collective
   - Comment on an existing note by the viewer
   - Vote on an open decision (creates audit-chain entries)
   - Set bio/location/website on `/settings`

3. Browser context B: log in as the viewer. Confirm you can see Dave's note,
   comment, and vote attributed to "Deleting Dave".

### Checklist

- [ ] Dave has: note, comment, vote, profile fields, forwarder rule, agent,
      trustee authorizations both directions, Stripe customer, accounts on
      two subdomains
- [ ] Dave is logged in in context A; viewer in context B

## Test 1: Sole-admin block (console and confirm page)

### Steps

1. Console: make Dave the sole admin of the shared collective:
   ```ruby
   cm = collective.collective_members.find_by(user_id: dave.id)
   cm.add_role!("admin")
   # ensure no other member holds the admin role
   ```
2. Browser (Dave): go to `/settings`, open the Delete Account section, and
   follow the link to `/account/deletion/new` (reverify when prompted).
3. Attempt the scrub directly:
   ```ruby
   ddm = DataDeletionManager.new(user: dave)
   ddm.delete_user!(user: dave, confirmation_token: ddm.confirmation_token)
   ```
4. Transfer the role and remove Dave's:
   ```ruby
   other = collective.collective_members.find_by(user_id: viewer.id)
   other.add_role!("admin")
   cm.remove_role!("admin")
   ```

### Checklist

- [ ] The confirm page shows an "Action needed" box naming the collective
      before anything is submitted (no surprises at submit time)
- [ ] Step 3 raises, naming the collective handle and `update_member_roles`
- [ ] Nothing was scrubbed (Dave's email unchanged, context A still works)
- [ ] After step 4, the confirm page no longer shows the blocker

## Test 2: Per-subdomain deletion — request, confinement, restore

### Steps

1. Browser (Dave, on the first subdomain): `/account/deletion/new`.
2. Choose "Delete my account on this subdomain only", submit, accept the
   confirm dialog.
3. Try to open any page on the first subdomain (e.g. `/settings`).
4. Open the second subdomain — Dave's account there should work normally.
5. Check mailcatcher for the confirmation email.
6. Back on the first subdomain: from the deletion status screen, restore.

### Checklist

- [ ] The scope choice shows both options with NEITHER pre-selected; the
      confirm dialog text does not promise a sign-out
- [ ] After submit: redirected to the status screen with subdomain-specific
      copy (login, other subdomains untouched)
- [ ] Every page on the first subdomain redirects to `/account/deletion`;
      the second subdomain is unaffected; Dave stays logged in
- [ ] Confirmation email says the request covers this subdomain only and
      links the restore screen
- [ ] After restore: first subdomain works again; forwarder rule re-enabled
      (`AutomationRule` check in console)

## Test 3: Global deletion request via settings

### Steps

1. Browser (Dave): `/account/deletion/new`, choose "Delete my account
   everywhere", submit, accept the confirm dialog.
2. Check mailcatcher for the confirmation email.
3. Log back in as Dave (password + `333333`) and try to open `/` or
   `/settings`.
4. Console: verify the lock:
   ```ruby
   dave.reload.pending_deletion?                                              # true
   AutomationRule.for_user_across_tenants(dave).where(enabled: true).count    # 0
   ApiToken.for_user_across_tenants(dave).where(deleted_at: nil).count        # 0
   ```

### Checklist

- [ ] After submit: lands on `/logout-success` (same origin — NOT bounced to
      the auth subdomain) with the "scheduled for deletion on <date>" notice
- [ ] Confirmation email names the deletion date and the restore link
- [ ] After re-login, every page redirects to the `/account/deletion` status
      screen showing the deletion date and a restore button
- [ ] Console checks return the expected values

## Test 4: Restore via the status screen

### Steps

1. Browser (Dave, logged in, on the status screen): click Restore.

### Checklist

- [ ] Redirected home with "Your account has been restored."
- [ ] `/settings` and the rest of the app work again on both subdomains
- [ ] Forwarder rule re-enabled; pre-existing disabled rules stay disabled

## Test 5: Admin view of a pending deletion

### Steps

1. Browser (Dave): request global deletion again (as in Test 3).
2. Browser context B: as an app_admin (grant the viewer `app_admin` in
   console if needed), open `/app-admin/users/<dave.id>`.

### Checklist

- [ ] PENDING DELETION badge and a warning box with the scheduled date
- [ ] Restore Account button present; Request Account Deletion hidden
- [ ] (If Dave were also suspended, the box would note the user cannot
      restore it themselves)

## Test 6: Reminder email and the scheduled scrub

### Steps

1. Console: move the request into the reminder window and run the job:
   ```ruby
   lead = AccountDeletionService::GRACE_PERIOD - AccountDeletionService::REMINDER_LEAD
   dave.reload.update!(deletion_requested_at: (lead + 1.hour).ago)
   AccountDeletionScrubJob.new.perform
   AccountDeletionScrubJob.new.perform   # idempotency: no second reminder
   ```
2. Check mailcatcher: exactly one reminder, naming the deletion date.
3. Console: expire the grace window and run the scrub:
   ```ruby
   dave.reload.update!(deletion_requested_at: (AccountDeletionService::GRACE_PERIOD + 1.day).ago)
   AccountDeletionScrubJob.new.perform
   ```

### Checklist

- [ ] Exactly one reminder email despite two job runs
- [ ] After step 3: `dave.reload.scrubbed_at` is set; email ends in
      `@deleted.user`; `name` is "Deleted User"

## Test 7: Access termination

### Steps

1. Browser context A (Dave's session): refresh or navigate to any page
2. Console: check credentials and delegations:
   ```ruby
   ApiToken.for_user_across_tenants(dave).where(deleted_at: nil).count       # 0
   RefreshToken.where(user_id: dave.id, revoked_at: nil).count               # 0
   TrusteeGrant.for_user_across_tenants(dave).where(revoked_at: nil, declined_at: nil).count # 0
   AutomationRule.for_user_across_tenants(dave).where(deleted_at: nil).count # 0
   TenantUser.for_user_across_tenants(agent).map(&:archived_at)              # all set
   ```

### Checklist

- [ ] Context A is bounced to login; Dave cannot log back in (identity destroyed)
- [ ] All five console checks return the expected values
- [ ] Dave's bio/location/website are nil; handle is randomized `…-deleted`
      on BOTH subdomains; both tenant_users have `scrubbed_at` set

## Test 8: What other members see

### Steps

1. Browser context B (viewer): open Dave's note, the note Dave commented on,
   and the decision Dave voted on

### Checklist

- [ ] Note and comment render with author "Deleted User"; content intact
- [ ] Dave's old handle and "Deleting Dave" appear nowhere on those pages
- [ ] The decision's vote counts are unchanged
- [ ] The admin user page (`/app-admin/users/<dave.id>`) shows the DELETED
      badge

## Test 9: Audit chain

### Steps

1. As the viewer, open the decision's verify page (`…/verify`)

### Checklist

- [ ] The chain verifies as valid (no tamper errors)
- [ ] Dave's entries show as scrubbed/unattributable, not as tampered
- [ ] The viewer's own entries still verify as attributed

## Test 10: Billing closure

### Steps

1. Stripe sandbox dashboard (or console:
   `Stripe::Customer.retrieve("<cus_id>")` and check `deleted`): look up the
   recorded customer id
2. Console: `StripeCustomer.find_by(stripe_id: "<cus_id>").active`

### Checklist

- [ ] Stripe shows the customer deleted
- [ ] Local StripeCustomer row exists with `active: false`

## Test 11: Idempotent re-run

### Steps

1. Console:
   ```ruby
   ddm2 = DataDeletionManager.new(user: dave.reload)
   ddm2.delete_user!(user: dave, confirmation_token: ddm2.confirmation_token)
   ```

### Checklist

- [ ] Second run completes without error (Stripe 404s are absorbed; no
      double-scrubbing side effects)
