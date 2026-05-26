# ApplicationController auth pipeline refactor (deferred)

Status: **deferred**. Capture so it isn't lost. Do not start while [anonymous-read-access-main-collective.md](anonymous-read-access-main-collective.md) is in flight.

## Why

[`app/controllers/application_controller.rb`](app/controllers/application_controller.rb) is 1285 lines, `typed: false`, and entangles identity resolution with access enforcement and membership maintenance. Specifically:

1. **`current_user` (line 191) is not a pure resolver.** It calls `resolve_browser_session_user` → `validate_access` → `validate_unauthenticated_access`, which can redirect, render JSON, or render an unauthorized response. A method named "current_user" should return the user, not perform request termination as a side effect. This is also why the auth gate isn't visible as a `before_action` — new readers have to chase three call sites to find it.

2. **`validate_authenticated_access` (line 492) is overloaded.** It validates membership AND performs three classes of side effects: `Tenant#add_user!` (create tenant_user), `Collective#add_user!` (create collective_member), `CollectiveMember#touch` (last-seen tracking). It also handles representation-grant validation. The name is misleading; at minimum, membership creation and last-seen-touch should split out.

3. **~8 chained gates each duplicate exemption knowledge.** `check_session_timeout`, `check_user_suspension`, `check_activation_gate`, `check_stripe_billing_gate`, `check_collective_archived`, `ActionCapabilityCheck#check_capability_for_action`, plus the two `validate_*` methods, each independently check `is_auth_controller?` and/or `api_token_present?`. Adding a new exempt controller means editing several gates. A single `AuthorizationPipeline` with declared exemptions would centralize this.

4. **Domain `current_*` accessors are auth-adjacent but conceptually separate.** `current_note`, `current_decision`, `current_commitment`, `current_decision_participant`, `current_commitment_participant`, `current_votes`, `current_cycle`, `current_resource`, etc. — these are routing helpers, not authorization. Extracting to a `RouteResolvers` concern would shrink ApplicationController and clarify intent.

5. **`typed: false` on the most-imported file.** Refactor is the right moment to land `typed: true` and regenerate RBIs.

## Target shape (sketch — not a spec)

- `current_user` becomes pure: returns the resolved user or `nil`. No redirects, no rendering.
- Explicit `before_action :enforce_access` (or similar) that runs after identity resolution and is the *sole* place the gate logic lives. Bypass conditions (anonymous-read, token auth, auth controller, etc.) declared as data, not chained `return if`s.
- `validate_authenticated_access` split into:
  - `enforce_tenant_membership` (decides allow/redirect; no writes)
  - `ensure_tenant_membership` (creates `tenant_user` when policy permits)
  - `ensure_collective_membership` (creates `collective_member` on main, redirects elsewhere)
  - `touch_collective_membership` (last-seen — could move to a job)
- Exemption registry: each gate declares the controllers/actions it skips, instead of every gate calling `is_auth_controller?` and friends.
- `RouteResolvers` concern absorbing `current_note`/`current_decision`/`current_commitment`/`current_*` lookups.
- `typed: true` + tapioca RBIs regenerated.

## Constraints when this lands

- **Do not start while anonymous-read-access is in flight.** That feature inserts the bypass at [validate_unauthenticated_access:562-579](app/controllers/application_controller.rb#L562-L579) and adds the `allows_anonymous` macro. Both should ship and bake before structure underneath them moves. The macro is actually a small step *toward* this refactor (class-level metadata for permissible access) and should be preserved.
- **Phase 5 route-introspection sweep test** ([from the anon-read plan](anonymous-read-access-main-collective.md#L216)) is the safety net for this refactor. Don't drop it.
- **Don't bundle with another security-sensitive feature.** Refactor in its own PR with focused review.
- Preserve behavior for: representation sessions, API token auth (including the X-Representation-Session-ID flow), feature-flag/billing/activation gates, archived-collective handling.
- Token auth flow (`resolve_api_user` → `api_authorize!` → `validate_scope`) is reasonably well-scoped today; the refactor doesn't need to disturb it, only realign it under the new pipeline.

## Estimated shape

1–2 day refactor if scoped tightly. Risks:

- Subtle ordering changes in the `before_action` chain (the current comment at [application_controller.rb:19-22](app/controllers/application_controller.rb#L19-L22) about `ActionCapabilityCheck` and `append_before_action` is the kind of fragile-ordering thing that bites refactors).
- Representation session handling is non-obvious; preserve all four validation steps in [resolve_browser_representation:398-448](app/controllers/application_controller.rb#L398-L448).
- The `add_user!` membership-creation side effects of `validate_authenticated_access` are how some users get added to collectives — splitting these out means making sure the new pipeline still invokes them at the right time.

## When to revisit

Triggers worth treating as "this is the moment":
- Next time auth/access logic needs non-trivial work (a new gate, a new exemption mode, multi-role).
- When `typed: false` blocks a Sorbet-related task.
- When a new contributor reports being confused by where the auth check lives.

Until one of those, this stays in the queue.
