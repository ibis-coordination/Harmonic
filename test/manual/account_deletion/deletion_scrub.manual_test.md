---
passing: false
last_verified: null
verified_by: null
---

# Test: Account Deletion Scrub (end to end)

Walks the full deletion causal chain in a development environment with the Stripe
sandbox: build a departing user with every kind of footprint, run the console
scrub, and verify each observable consequence — access termination, "Deleted
User" rendering, audit-chain scrubbing, billing cleanup, and idempotent re-run.
Run before merging changes to `DataDeletionManager#delete_user!` or building
closure flows on top of it.

## Prerequisites

- Dev environment running (`./scripts/start.sh`)
- Stripe sandbox key configured (`STRIPE_API_KEY` — verify with
  `docker compose exec web printenv STRIPE_API_KEY | head -c 8`)
- A tenant + collective with at least one existing member you can act as
  (the "viewer") besides the departing user
- Two browser contexts (e.g. a normal and a private window), or one browser
  plus the markdown UI via curl

## Setup: build the departing user's footprint

1. Rails console (`./scripts/rails-c.sh`):

   ```ruby
   tenant = Tenant.find_by!(subdomain: "app")   # adjust to your tenant
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
      trustee authorizations both directions, Stripe customer
- [ ] Dave is logged in in context A; viewer in context B

## Test 1: Sole-admin block

### Steps

1. Console: make Dave the sole admin of the shared collective:
   ```ruby
   cm = collective.collective_members.find_by(user_id: dave.id)
   cm.add_role!("admin")
   # ensure no other member holds the admin role
   ```
2. Attempt the scrub:
   ```ruby
   ddm = DataDeletionManager.new(user: dave)
   ddm.delete_user!(user: dave, confirmation_token: ddm.confirmation_token)
   ```
3. Transfer the role and remove Dave's:
   ```ruby
   other = collective.collective_members.find_by(user_id: viewer.id)
   other.add_role!("admin")
   cm.remove_role!("admin")
   ```

### Checklist

- [ ] Step 2 raises, naming the collective handle and `update_member_roles`
- [ ] Nothing was scrubbed (Dave's email unchanged, context A still works)
- [ ] After step 3, no error is raised when Test 2 runs

## Test 2: Execute the scrub

### Steps

1. Console:
   ```ruby
   ddm = DataDeletionManager.new(user: dave)
   ddm.delete_user!(user: dave, confirmation_token: ddm.confirmation_token)
   ```

### Checklist

- [ ] Returns the success message; no exception
- [ ] `dave.reload.email` ends in `@deleted.user`; `name` is "Deleted User"
- [ ] `dave.sessions_revoked_at` is set

## Test 3: Access termination

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

## Test 4: What other members see

### Steps

1. Browser context B (viewer): open Dave's note, the note Dave commented on,
   and the decision Dave voted on

### Checklist

- [ ] Note and comment render with author "Deleted User"; content intact
- [ ] Dave's old handle and "Deleting Dave" appear nowhere on those pages
- [ ] The decision's vote counts are unchanged

## Test 5: Audit chain

### Steps

1. As the viewer, open the decision's verify page (`…/verify`)

### Checklist

- [ ] The chain verifies as valid (no tamper errors)
- [ ] Dave's entries show as scrubbed/unattributable, not as tampered
- [ ] The viewer's own entries still verify as attributed

## Test 6: Billing closure

### Steps

1. Stripe sandbox dashboard: look up the recorded customer id
2. Console: `StripeCustomer.find_by(stripe_id: "<cus_id>").active`

### Checklist

- [ ] Stripe dashboard shows the customer deleted
- [ ] Local StripeCustomer row exists with `active: false`

## Test 7: Idempotent re-run

### Steps

1. Console:
   ```ruby
   ddm2 = DataDeletionManager.new(user: dave.reload)
   ddm2.delete_user!(user: dave, confirmation_token: ddm2.confirmation_token)
   ```

### Checklist

- [ ] Second run completes without error (Stripe 404s are absorbed; no
      double-scrubbing side effects)
