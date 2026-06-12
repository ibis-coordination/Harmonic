# Billing Review Fixes

A correctness review of the billing system (2026-06-11) found ten issues: eight behavior bugs, one display bug, and one piece of dead code. This plan fixes all of them, plus one small feature that fell out of the review (an admin toggle for collective billing exemption, Phase 10). Each phase lands with its own tests (red first, then green); ordering constraints are in Execution Notes.

## Findings Summary

| # | Issue | Severity |
|---|-------|----------|
| 1 | `BillingReconciliationJob` is never scheduled — the "daily safety net" doesn't run | High |
| 2 | Admin billing-exempt toggle on an AI agent never syncs the parent's Stripe quantity | High |
| 3 | Human-user `billing_exempt` is never honored — exempted humans with API tokens are still billed and gated | High |
| 4 | Subscription loss suspends/lapses billing-exempt resources, which require no subscription | Medium |
| 5 | `POST /billing/setup` has no already-active guard — a second checkout creates a duplicate Stripe subscription | Medium |
| 6 | `checkout.session.completed` webhook doesn't activate pending resources — only the synchronous return path does | Medium |
| 7 | `/billing` inventory self-line checks API tokens only — webhook-billed users see "free" while charged $3 | Medium |
| 8 | `BillingController#find_owned_collective` is dead code | Low |
| 9 | Cancel-at-zero-quantity forfeits unused time and destroys pending proration credits | Medium |
| 10 | The existing billing-exempt toggle is half-broken: its describe endpoint 500s (`toggle_billing_exempt` missing from `ACTION_DEFINITIONS`) and no admin view renders a button for it | Medium |

Severity compounds across findings: 2, 4, and 5 all lean on the reconciliation job as a backstop, and finding 1 means that backstop never runs.

---

## Phase 1: Schedule BillingReconciliationJob

**Problem.** `config/initializers/sidekiq_cron.rb` has no entry for `BillingReconciliationJob`. Nothing else schedules it (no Procfile, rake task, or CI cron). The job exists, has tests, and several code paths depend on it: sync-failure flash messages promise "your next invoice will reflect this within 24 hours" (`BillingController#deactivate_agent`, `CollectivesController#downgrade`), and pending-resource recovery assumes a daily sweep.

**Fix.**
1. Extract the schedule hash in `config/initializers/sidekiq_cron.rb` to a top-level frozen constant (e.g. `SIDEKIQ_CRON_SCHEDULE`) so it is loadable outside the `Sidekiq.configure_server` block (which never runs in the test env).
2. Add the entry:
   ```ruby
   "billing_reconciliation" => {
     "cron" => "0 2 * * *", # Daily at 2 AM
     "class" => "BillingReconciliationJob",
     "description" => "Reconcile Stripe subscription quantities and recover stuck pending resources",
   },
   ```

**Tests (red first).**
- Schedule includes a `billing_reconciliation` entry whose class is `BillingReconciliationJob`.
- Every `class` value in the schedule constantizes to an `ApplicationJob`/`SystemJob` descendant (guards against typos for all entries, not just this one).

**Files.** `config/initializers/sidekiq_cron.rb`, new `test/initializers/sidekiq_cron_schedule_test.rb` (or equivalent location matching existing test layout).

**Verification.** Boot the stack and confirm the job appears in the Sidekiq cron UI / `Sidekiq::Cron::Job.all`.

---

## Phase 2: Sync parent subscription when toggling agent exemption

**Problem.** `AppAdminController#execute_toggle_billing_exempt` syncs `StripeService.sync_subscription_quantity!(user) if user.human?`. Toggling exemption on an AI agent changes the **parent's** `billable_quantity` (agents are counted via `User#active_billable_agent_count`, which filters `billing_exempt: false`), but no sync happens — Stripe drifts until reconciliation. The unsuspend action in the same controller already handles this correctly (`execute_unsuspend_user` syncs the parent for agents).

**Fix.** In `execute_toggle_billing_exempt`, resolve the billing owner before syncing:
- human → sync the user themselves
- AI agent with a parent → sync the parent

Check the `SyncResult` and reflect failure in the response (other billing paths use a "your next invoice will reflect this within 24 hours" notice on sync failure — with Phase 1 landed, reconciliation genuinely backstops it).

**Tests (red first).**
- Toggling exemption on an AI agent calls `sync_subscription_quantity!` with the parent (follow the stubbing pattern used by existing app-admin billing tests).
- Toggling exemption on a human still syncs that human (regression).
- Audit log entries unchanged for both cases.

**Files.** `app/controllers/app_admin_controller.rb`, `test/controllers/app_admin_controller_test.rb`.

---

## Phase 3: Honor billing_exempt on human users

**Problem.** `User#counts_self_for_paid_human_features?` (and its sub-checks `counts_self_for_api_access?` / `has_notification_webhook?`) never consult `billing_exempt?`. An app admin can toggle exemption on a human — it's audit-logged and syncs — but has zero billing effect: the user is still charged the $3/month personal-programmatic-access line and still hits the application billing gate. The admin toggle on humans is effectively a no-op.

**Fix.** Add `return false if billing_exempt?` to `counts_self_for_paid_human_features?`.

**Scope guard — exemption must NOT cascade.** A user-level exemption exempts only the user's *own* +1. Their agents and collectives keep their own `billing_exempt` flags and keep billing normally. (The failed promo-code attempt died on exactly this cascade — see `memory/feedback_billing_promo_codes.md`. The flag adjusts the quantity; it must not skip billing code paths.)

**Call-site audit.** `counts_self_for_api_access?` is also called directly from the `/billing` views (see Phase 7). Grep all callers of both sub-methods and decide per-site whether they want the raw check ("does the user hold a token?") or the billing-effective check ("is the user charged for it?").

One call site is already confirmed broken for exempt users: `ApiTokensController#needs_stripe_setup_for_token?` checks only `human?` / admin / `stripe_customer&.active?` — it would send an exempt human to Stripe Checkout for their first token. Add a `billing_exempt?` early return there. `NotificationWebhooksController` follows the same pattern and needs the same check.

**Tests (red first)** — the interaction matrix:
- Exempt human + active external API token → `billable_quantity == 0`.
- Exempt human + token → billing gate passes (no redirect to `/billing`).
- Exempt human creates their first token → no Stripe Checkout required.
- Exempt human + non-exempt agent → quantity counts the agent (no cascade).
- Non-exempt human + token → quantity includes +1 (regression).
- Revoking exemption on a human with a token → sync called, quantity returns to 1.
- Exempt human + notification webhook → quantity 0 (webhook path, not just tokens).

**Docs.** Update the BILLING.md exemptions paragraph: human self-exemption is honored and excludes the personal-programmatic-access line from the quantity.

**Files.** `app/models/user.rb`, `app/controllers/api_tokens_controller.rb`, `app/controllers/notification_webhooks_controller.rb`, `test/models/user_test.rb` or a dedicated billing-quantity test file, `docs/BILLING.md`.

---

## Phase 4: Don't deactivate exempt resources on subscription loss

**Problem.** `StripeService.deactivate_resources_for_customer` suspends every non-suspended agent and lapses every paid collective on billing-enabled tenants, with no `billing_exempt` filter. Exempt resources don't require a subscription, so losing the subscription shouldn't touch them. Phase 3 makes this path much more reachable: granting exemption to a human whose remaining resources are all exempt drops `billable_quantity` to 0, sync auto-cancels the subscription, and the resulting `customer.subscription.deleted` webhook would suspend the very resources that were just exempted.

**Fix.** Add `billing_exempt: false` to both queries in `deactivate_resources_for_customer` (the agent suspension scope and the collective lapse scope).

The restore path needs no change: exempt collectives never enter `lapsed` after this fix, and `restore_lapsed_collectives_for` only targets `TIER_LAPSED`.

**Tests (red first).**
- `customer.subscription.deleted` webhook: exempt agent stays unsuspended; non-exempt agent is suspended (regression).
- Same event: exempt paid collective stays `paid`; non-exempt paid collective lapses (regression).
- The Phase 3 end-to-end: exempt a human whose only resources are exempt → subscription cancels → nothing gets suspended or lapsed.

**Files.** `app/services/stripe_service.rb`, `test/services/stripe_service_test.rb`.

---

## Phase 5: Guard POST /billing/setup against an active subscription

**Problem.** `BillingController#setup` creates a subscription-mode Checkout session without checking whether the user already has an active subscription. The UI hides the button when active, but a direct POST creates a second checkout; completing it creates a **second Stripe subscription**. The webhook then repoints `stripe_subscription_id` at the new one and the stale-event guard ignores everything from the old subscription — which keeps charging the customer with no way to detect it app-side.

**Fix.** At the top of `setup`, redirect to `/billing` with a notice when `current_user.stripe_customer&.active?`. (The lapsed-state "Resume billing" button is unaffected — the customer is inactive then.)

**Tests (red first).**
- POST `/billing/setup` with an active customer → redirect to `/billing`, and `Stripe::Checkout::Session.create` is never called.
- POST with an inactive/lapsed customer still reaches checkout (regression — covers the Resume billing flow).
- POST with no customer at all still reaches checkout (regression).

**Files.** `app/controllers/billing_controller.rb`, `test/controllers/billing_controller_test.rb`.

---

## Phase 6: Activate pending resources from the webhook

**Problem.** Clearing `pending_billing_setup` happens only in `BillingController#handle_checkout_return` (synchronous return) and the reconciliation job. The `checkout.session.completed` webhook activates the customer but not the pending resources. A user who pays on Stripe and closes the tab keeps pending (unusable) agents and collectives until reconciliation — which, before Phase 1, never ran.

**Fix.** Extract the activation logic from `BillingController#activate_pending_resources!` into a shared method (e.g. `StripeService.activate_pending_resources_for(user, stripe_customer)`) and call it from both:
- `BillingController#handle_checkout_return` (inside the existing row-lock transaction, as today), and
- `StripeService.handle_subscription_checkout_completed`, after the customer activates.

The operation is naturally idempotent (`update_all` on a `where(pending_billing_setup: true)` scope), so webhook + return-path double execution is safe. No extra quantity sync is needed: pending agents are already included in `billable_quantity` (no `pending_billing_setup` filter in the count methods), so the checkout quantity already covered them.

**Note on collectives:** nothing sets `pending_billing_setup: true` on collectives anymore — the only writer is the agent-creation flow; collective pending became unreachable when the explicit tier model replaced creation-time billing. The shared method should still clear collective pending flags (matching the return path and the reconciliation job) to heal any legacy rows, but the collective side is defensive, not a live flow. Full removal of the vestigial collective-pending state is out of scope (see below).

**Tests (red first).**
- `checkout.session.completed` webhook with a pending agent → `pending_billing_setup` cleared and `stripe_customer_id` backfilled.
- Pending agent on a different billing-enabled tenant also activates (cross-tenant).
- Legacy pending collective (flag set directly in the test — no creation flow produces it) → cleared.
- Webhook fires after the return path already activated → no error, no state change (idempotency).
- Return-path behavior unchanged (regression on existing `handle_checkout_return` tests).

**Files.** `app/services/stripe_service.rb`, `app/controllers/billing_controller.rb`, `test/services/stripe_service_test.rb`, `test/controllers/billing_controller_test.rb`.

---

## Phase 7: Show webhook-driven billing on the /billing self-line

**Problem.** The inventory self-line (`app/views/billing/_inventory_table.html.erb:9`, `show.md.erb:14` and `:111`) checks `counts_self_for_api_access?` only. A user billed via a notification webhook (no API token) sees "free" while being charged $3/month — the itemization no longer matches the invoice.

**Fix.** Switch the views to `counts_self_for_paid_human_features?` and label the line to cover both cases (e.g. "API access / webhooks"). After Phase 3, this also makes an exempt user's self-line read correctly (the method returns false → "free"); if a clearer "exempt" label is wanted on the self-line, add it the way agent/collective rows do.

**Tests (red first).**
- `/billing` (HTML and markdown) for a user with a notification webhook and no token shows the $3 self-line.
- User with a token still shows it (regression).
- Exempt user with a token shows free/exempt, not $3 (depends on Phase 3).

(The label change must also keep the markdown API view (`show.md.erb`) and HTML view consistent with each other.)

**Files.** `app/views/billing/_inventory_table.html.erb`, `app/views/billing/show.md.erb`, `test/controllers/billing_controller_test.rb` (or wherever billing view assertions live).

---

## Phase 8: Remove dead code

`BillingController#find_owned_collective` has no callers (the deactivate/reactivate routes exist only for agents). Delete it. No new tests; the existing suite confirms nothing breaks.

---

## Phase 9: Credit unused time when the subscription cancels at zero quantity

**Problem.** When a user's last billable item is removed, `StripeService.cancel_subscription_for_zero_quantity!` calls `Stripe::Subscription.cancel(id)` with no params. Stripe's defaults for immediate cancellation are `prorate: false` / `invoice_now: false`, which means (per Stripe's docs):

- no credit is created for the unused remainder of the current period, **and**
- *pending prorations are removed* — so a credit earned from an earlier quantity decrease that hasn't been invoiced yet is destroyed along with the subscription.

Worst case: a user removes one agent mid-month (credit goes pending) and their last agent a few days later (cancel wipes the pending credit) — they paid a full month for both and are credited for neither.

**Fix.** Cancel with `prorate: true, invoice_now: true`. That generates a final invoice that includes the unused-time proration (and any pending prorations); a negative-total invoice credits the customer's Stripe balance, which automatically offsets future invoices. Because resubscribing reuses the same Stripe customer (`find_or_create_customer` returns the existing record; `/billing/setup` opens a new subscription on it), the balance applies if the user ever comes back.

**Tests (red first).** Our tests mock Stripe, so they can only pin our parameters:
- `cancel_subscription_for_zero_quantity!` passes `prorate: true, invoice_now: true` to `Stripe::Subscription.cancel`.
- Local effects unchanged: `active: false`, `stripe_subscription_id` retained (regression).

**Manual verification (required — mocks can't prove Stripe's side).** In Stripe test mode: subscribe with quantity 2, decrease to 1 mid-period, then drop to 0. Confirm the final invoice carries the negative proration lines and the customer balance shows the credit; then resubscribe and confirm the balance offsets the new subscription's first invoice.

**Docs.** Update the "One Subscription" paragraph in `app/views/help/billing.md.erb` — the current text says removing the last item yields "no credit or refund," which this phase makes obsolete. New behavior: unused time is credited to the account and applies automatically if billing is set up again. Update BILLING.md's lapse/cancel notes to match.

**Files.** `app/services/stripe_service.rb`, `test/services/stripe_service_test.rb`, `app/views/help/billing.md.erb`, `docs/BILLING.md`.

---

## Phase 10: Billing-exempt admin toggles — repair the existing one, add one for collectives

**Problem.** The user/agent exemption toggle exists only as routes: no admin view renders a button for it, and `GET /app-admin/users/:id/actions/toggle_billing_exempt` raises `ArgumentError: Unknown action` (verified in console) because `toggle_billing_exempt` was never added to `ActionsHelper::ACTION_DEFINITIONS` — `action_description` raises on unknown keys. Collectives have no toggle at all; their `billing_exempt` flag is honored throughout the quantity/gate logic but is settable only via console.

**Fix.**
1. **Repair the describe endpoint:** add a `toggle_billing_exempt` entry to `ACTION_DEFINITIONS` (description + params, mirroring `suspend_user` / `unsuspend_user`).
2. **Make the existing toggle visible:** add the toggle button to `app/views/app_admin/show_user.html.erb` (and the `.md.erb` actions surface), next to the suspend/unsuspend buttons, showing current exemption state.
3. **Add the collective toggle:** route pair `GET`/`POST /app-admin/collectives/:id/actions/toggle_billing_exempt` mirroring the user version. The execute action: look up via `Collective.unscoped_for_admin`, no-op for main collectives (never billed), flip the flag, sync the owner's subscription (`created_by`, same billing-owner resolution as Phase 2, surfacing `SyncResult` failure), and audit-log via `SecurityAuditLog.log_admin_action`.
4. **Button placement for collectives:** a Collectives section on the admin tenant page (`/app-admin/tenants/:subdomain`) listing each collective's tier/exemption with a toggle button. (The collective settings page was considered but doesn't work: `/app-admin` routes are restricted to the primary subdomain, while settings pages live on each tenant's subdomain — a relative form POST would 404.)

**Tests (red first).**
- `GET /app-admin/users/:id/actions/toggle_billing_exempt` renders instead of raising (pins the `ACTION_DEFINITIONS` repair).
- Collective toggle: flag flips, owner's subscription synced, audit log written.
- Main collective → no-op (no flag change, no sync).
- Non-admin → 403; admin UI elements hidden from non-admins on the settings page.
- Exemption + quantity behavior is already covered by existing count tests (no duplication needed).

**Docs.** Update the BILLING.md exemptions paragraph — it currently says collective exemption "has no admin surface yet and is set via console," which this phase obsoletes.

**Files.** `app/services/actions_helper.rb`, `app/controllers/app_admin_controller.rb`, `config/routes.rb`, `app/views/app_admin/show_user.html.erb`, `app/views/app_admin/show_user.md.erb`, `app/views/collectives/settings.html.erb` (+ `.md.erb`), `test/controllers/app_admin_controller_test.rb`, `docs/BILLING.md`.

---

## Out of Scope

- **Billing ownership transfer (`billing_owner_id`)** and **promo codes** — tracked separately as design debt. Phase 10's toggle syncs `created_by` and doesn't prejudge the ownership work.
- **Removing the vestigial collective-pending state** — `pending_billing_setup` on collectives has no remaining writer (see Phase 6); ripping out the column usage (billing-page pending section, `check_collective_archived` gate branch, reconciliation sweep) deserves its own small cleanup after confirming production has no rows with the flag set.
- **CHANGELOG** — update post-merge, not on the feature branch.

## Execution Notes

- Branch: `billing-review-fixes`, off `main` after the `docs-refresh` branch merges (the BILLING.md corrections and `/help/billing` topic live there).
- Order: land Phase 1 first — it restores the safety net the other findings currently lack. Phase 4 must land with or before Phase 3 (Phase 3 makes the exempt-resource deactivation path reachable via auto-cancel). Phase 9 pairs naturally with 3+4: the exemption flow auto-cancels at zero quantity, and with Phase 9 the user gets their unused time back instead of forfeiting it. Phase 10 lands after Phase 2 (both rework `execute_toggle_billing_exempt`'s sync logic). Otherwise phases are independent: 3+4+9, then 2, 10, 5, 6, 7, 8.
- Every phase: red test → green → rubocop → `srb tc`. Targeted test files only; full suite in CI.
