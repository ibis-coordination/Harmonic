# Anonymous read-only access to the main (public) collective

## Goal

Bring runtime behavior in line with [`app/views/help/privacy.md.erb`](app/views/help/privacy.md.erb): the **main collective is the public space**. Anonymous visitors can read notes, decisions, commitments, comments, votes/participants, and attachments there. Non-main collectives stay members-only.

Read-only. Anonymous reach is limited to:

- The three item URLs: `/n/:note_id`, `/d/:decision_id`, `/c/:commitment_id`.
- The help docs: `/help` and `/help/:topic` (universal documentation; no user content).

Root path and everything else still redirects to `/login`. HTML + `text/markdown` (the dual interface); JSON/API stays token-gated.

**Hard invariant:** any tenant *not* explicitly listed as anonymous-readable has zero anonymous visibility, on any URL, in any format. Enforced by a route-introspection sweep test (Phase 5), not by enumeration.

## Current state (verified)

- `ApplicationController#validate_unauthenticated_access` ([app/controllers/application_controller.rb:562-579](app/controllers/application_controller.rb#L562-L579)) redirects every unauthenticated request to `/login` unless `tenant.require_login?` is false (only true for the synthetic AUTH_SUBDOMAIN tenant).
- `Collective.scope_thread_to_collective` ([app/models/collective.rb:48-74](app/models/collective.rb#L48-L74)) defaults `Collective.current_id` to `tenant.main_collective` when no `:collective_handle`. The `ApplicationRecord` default scope then auto-restricts every query — **no item-level visibility flag needed**.
- No `visibility` / `public` fields exist on Note/Decision/Commitment. The stub `Decision#public?` at [decision.rb:188](app/models/decision.rb#L188) is unused dead code.
- `Tenant.all_public_tenants` exists but is used only for the subdomain directory page ([home_controller.rb:28](app/controllers/home_controller.rb#L28)). We do **not** reuse it — it conflates "listed in directory" with "anonymous-readable."
- Mime symbol for `text/markdown` is `:md` ([config/initializers/mime_types.rb:1](config/initializers/mime_types.rb#L1)).

## Design

### A. Public-tenant identification: new env var

```ruby
# app/models/tenant.rb
def public_main_collective?
  self.class.anon_readable_subdomains.include?(subdomain&.downcase)
end

def self.anon_readable_subdomains
  @anon_readable_subdomains ||= ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", "")
    .split(",").map { |s| s.strip.downcase }.reject(&:blank?).to_set.freeze
end
```

- Default-deny when unset (the safe default).
- Memoized per-process; test helper `with_anon_readable_subdomains(...)` in `test_helper.rb` resets the ivar between tests.
- Boot-time initializer (`config/initializers/anon_readable_tenants.rb`) warns (not fail-fast) for env-listed subdomains with no matching `Tenant`. Catches the silent-misconfig footgun.
- For Harmonic SaaS: set `ANON_READABLE_TENANT_SUBDOMAINS=app`. Self-hosted private: leave unset.

### B. Auth gate bypass

Extend `validate_unauthenticated_access` to short-circuit when **all** of:

1. `@current_user` is nil
2. `@current_tenant.public_main_collective?`
3. `@current_collective.is_main_collective?`
4. `request.get?` or `request.head?`
5. `self.class.allows_anonymous?(action_name.to_sym)`
6. `request.format.symbol` ∈ `{:html, :md}`

Insert as a new `return if anonymous_main_collective_read_allowed?` **after** the existing two `return if` lines and **before** the redirect, so auth-controller and token-authenticated exemptions keep behaving identically.

`require_login?` is **not** repurposed. Phase 1 includes a test pinning `Accept: text/markdown` → `:md` so a Rails upgrade can't silently break condition 6.

### C. Controller allowlist macro

```ruby
# ApplicationController
def self.allows_anonymous(*actions)
  @anonymous_actions = Set.new(actions.map(&:to_sym))
end

def self.allows_anonymous?(action)
  @anonymous_actions&.include?(action.to_sym) || false
end
```

Per-class `@anonymous_actions` instance variable — **does not inherit** to subclasses (each class has its own ivar slot). Deliberately not `class_attribute`, which *would* inherit and silently grant anon access to `Api::V1::*` subclasses.

Allowlist:

| Controller | Action(s) | URL(s) |
|------------|-----------|--------|
| `NotesController` | `show` | `/n/:id` |
| `DecisionsController` | `show` | `/d/:id` |
| `CommitmentsController` | `show` | `/c/:id` |
| `HelpController` | `:index, *TOPICS` | `/help`, `/help/:topic` |

`HelpController` declares via the existing constant: `allows_anonymous(:index, *TOPICS)` — keeps the allowlist in sync if topics are added/removed. Help is gated by the same 6 conditions: only on public tenants, only on the main collective context, only HTML/Markdown. Feature-gated topics (`api`, `agents`, `trio`) continue to 404 via `help_topic_available?` (a tenant-level check, no user dependency).

Grep audit: `rg "allows_anonymous "`.

### D. Caching

Anon and logged-in users hit the same URLs → must prevent cross-audience reuse. The three show actions set:

```ruby
response.headers["Cache-Control"] = "private, no-store, must-revalidate"
```

Phase 0 confirms there are no `Rails.cache.fetch` keys in show paths that omit user identity. Phase 3 e2e test: log in → view item → log out → refresh → must render anon view.

### E. Before-action gates and side effects

Phase 0 audits each of these and the show paths they feed, producing inventories that drive Phases 3-4. Expected outcome for each: already-gated on `current_user.present?`, no change needed. Tracked items:

- `ActionCapabilityCheck`: must not crash on nil user; not used as a redundant deny path (allowlist is the single enforcement point).
- `check_session_timeout`, `check_user_suspension`, `check_activation_gate`, `check_stripe_billing_gate`: all early-return on no `session[:user_id]` or no human user — confirm.
- `check_collective_archived`: redirects to /settings (login-gated) for archived collectives → anon double-redirects to /login. Acceptable.
- `validate_authenticated_access` auto-add to main collective: gated on `@current_user` present, anon skips naturally.
- DB mutations on GET: `current_decision_participant` (creates row, gated on user), `CollectiveMember.touch`, any "last viewed" / notification mark-as-read / pin / analytics writes. Any mutation must be gated or get an explicit anon-skip with a test asserting no row is created.

### F. View changes

Phase 0 produces a partial inventory for the three show paths. Implementation is per-partial: add `current_user.present?` guards where missing, swap in `shared/_login_to_act.html.erb` where interaction surfaces appear.

Categorical expectations:

- App chrome (nav, sidebar, notification bell): for anon, hide user-specific bits; show Log in / Sign up CTAs.
- Item show pages: hide Reply/Comment/Vote/Pledge/Pin/Report/Reaction controls; show their counts and listings.
- Attachments: show download links; hide upload control.

We change *interaction surfaces*, not *content*.

### G. Markdown / dual interface

Phase 0 inventories `current_user.foo` references in `notes/show.md.erb`, `decisions/show.md.erb`, `commitments/show.md.erb`, their shared partials, and `api_helper` calls. Anon markdown must contain no per-user data and no per-user action descriptions; the "Actions" footer should be empty or omitted.

### H. Privacy doc rewrite (deployment-aware, FQDN-explicit)

Rewrite [app/views/help/privacy.md.erb](app/views/help/privacy.md.erb) so every visibility claim names the actual FQDN:

```erb
<% fqdn = "#{@current_tenant.subdomain}.#{ENV['HOSTNAME']}" %>
```

- **Public Space** copy switches on `@current_tenant.public_main_collective?`:
  - True: "`<%= fqdn %>` is the public space. Everyone can see content posted here, including visitors who are not logged in."
  - False: "`<%= fqdn %>` is only visible to members."
- **Collectives** and **Workspace** sections also use `<%= fqdn %>` for concreteness (uniform across deployment modes).
- Summary table gets a footnote noting the deployment-mode rule.

### I. Rate limiting (ships inline)

Per-IP cap on anon GET to the three allowlisted URLs via the existing `RateLimits` concern. Initial limit: **60 req/min per IP**, rolling window, 429 on excess. Logged-in users not affected (they have their own per-user limits).

### J. Out of scope

- Anonymous discovery: search, feed, index of public items.
- Anonymous API token access.
- Per-item public flag inside non-main collectives.
- robots.txt / sitemap.xml / `X-Robots-Tag` / OG meta — **recommended near-term follow-up**, separate PR.
- Anon-clickable author links 302 to /login — known rough edge, documented, not fixed here.
- Public profile pages.
- Logged-in non-member behavior is unchanged (bypass fires only for `current_user.nil?`).

## Existing-content policy change

Deploy flips every main-collective item from logged-in-only to world-readable. Privacy doc has always described this as the model, so this aligns runtime with documented expectation. User decision: **no external comms** (few existing users, expectation already communicated). Still required: `CHANGELOG.md` entry, operator note on the env var, and a spot-check of historical content. Flag in the PR description.

## Implementation phases (TDD — failing tests first)

### Phase 0: Audit (read-only)

Produces `.claude/plans/anonymous-read-audit-notes.md` with four inventories driving Phases 1-4:

1. Reachable partials for `/n/:id`, `/d/:id`, `/c/:id`, and `/help[/topic]` HTML paths, with per-partial `current_user.foo` references.
2. Same for `.md.erb` markdown templates.
3. DB mutations reachable from those actions and how each is gated.
4. Verification notes on `ActionCapabilityCheck` and other before-action gates with nil user.

Help paths are expected to be minimal-chrome and free of per-user state (`@sidebar_mode = "minimal"`, no user context referenced in topic templates), but Phase 0 verifies rather than assumes.

On merge, audit file moves to `.claude/plans/completed/YYYY/MM/`.

### Phase 1: Gate plumbing + adversarial spec tests

Failing tests covering:

- `Tenant#public_main_collective?`: unset env, present subdomain, absent subdomain, case-insensitive, whitespace-tolerant, memoization reset.
- `ApplicationController.allows_anonymous` macro: declared returns true, undeclared returns false, subclass does NOT inherit, sibling controllers don't cross-contaminate, `ApplicationController.allows_anonymous?` returns false on base.
- `Accept: text/markdown` resolves `request.format.symbol == :md`.
- Boot validator: warns for unknown subdomains, silent when matched or unset.
- Gate bypass, against public + private tenant fixtures:
  - Public tenant, allowlisted action, HTML/Markdown → proceeds (after Phase 2 wires it up).
  - Public tenant, non-allowlisted action → 302 to /login.
  - Public tenant, allowlisted action but `?collective_handle=foo` (non-main) → 302.
  - Public tenant, allowlisted action, nonexistent collective handle → 404.
  - Private tenant, all three URLs → 302.
  - POST/PATCH/PUT/DELETE on the three URLs → 302.
  - JSON/CSV/XML formats on allowlisted URLs → 401/406/302.
  - Anon request → no crash anywhere in the before-action chain.

Then implement: `Tenant#public_main_collective?` + `anon_readable_subdomains`, the boot initializer, the `allows_anonymous` macro, the 6-condition bypass (per Section B insertion order), and delete the dead `Decision#public?` stub.

### Phase 2: Wire up the controllers

- `allows_anonymous :show` on `NotesController`, `DecisionsController`, `CommitmentsController`.
- `allows_anonymous(:index, *TOPICS)` on `HelpController`.
- Set Section D cache headers on the three show actions (help is static docs; standard public caching is fine, but apply the same headers for consistency).
- Apply Section I rate limiter to the three show actions. Help is excluded from the per-route rate limit (small static surface, unlikely abuse target — if abuse appears, add later).
- Controller-level integration tests for each: anon GET on public tenant returns 200 with HTML body; with `Accept: text/markdown` returns 200 markdown body. Help test covers `/help`, one regular topic (e.g. `/help/privacy`), and one feature-gated topic that 404s when the flag is off.
- Rate-limit test: anon burst of 60 to a show URL → 200s; 61st → 429; same IP logged-in → 200.

### Phase 3: View suppression

- Driven by Phase 0 partial inventory: per partial, confirm nil-user handling or add `current_user.present?` guards.
- Add `shared/_login_to_act.html.erb`.
- Manual checklist `test/manual/anonymous_read_access.manual_test.md` covers: anon view on public tenant, login round-trip, private-tenant rejection, root-path redirect, cache/auth-state-transition.
- One Playwright e2e for the auth-state-transition cache case.

### Phase 4: Markdown

- Per Phase 0 markdown inventory: add nil handling for `current_user.foo` references.
- Structural assertions (not byte snapshots — markdown contains IDs/timestamps that flake):
  - Anon markdown body contains no user handle from `User.pluck(:handle)`.
  - No frontmatter keys for read receipts / drafts / user-specific paths.
  - Actions footer empty or absent.
  - Anon body is a section-subset of authenticated body.

### Phase 5: Route-introspection sweep

`test/integration/anonymous_access_invariants_test.rb` iterates `Rails.application.routes.routes`:

- GET routes only. Skip mounted engines (Sidekiq Web, ActiveStorage, Rails health, Action Cable) via an explicit `SKIPPED_ENGINES` list. New engines fail the test until added with a comment.
- Synthetic path-param values like `"00000000"` — no fixture setup needed.
- **Any non-2xx counts as "denied"** (302/401/403/404 all pass). Any 2xx fails the test, unless the `(controller, action)` is in:
  ```ruby
  ANON_ALLOWED = {
    "notes" => [:show],
    "decisions" => [:show],
    "commitments" => [:show],
    "help" => [:index, *HelpController::TOPICS.map(&:to_sym)],
  }.freeze
  ```
- Run against both a public and a private tenant fixture.

Adding a new anon-allowed route requires: (1) `allows_anonymous` in the controller, (2) entry in `ANON_ALLOWED`, (3) code review justification.

Additional explicit cases (separate test methods):

- Allowlisted URL for an item in a non-main collective of a public tenant → 404.
- Cross-tenant ID guessing → 404.
- AUTH_SUBDOMAIN tenant → 404/redirect (no main collective; condition 3 fails).
- Misconfig: AUTH_SUBDOMAIN in `ANON_READABLE_TENANT_SUBDOMAINS` → still no anon reads.
- Subdomain-less request → existing error behavior unchanged.

If the sweep exceeds 30s, mark slow and run CI-only.

### Phase 6: Pre-release

Required to merge:

- `CHANGELOG.md` entry (visibility change + env var).
- Operator note on `ANON_READABLE_TENANT_SUBDOMAINS`.
- Privacy doc rewritten per Section H.
- Rate limiting per Section I.
- Spot-check of historical main-collective content.

Not in this PR: external comms (decided no), robots.txt/sitemap/OG (separate follow-up).

## Files

- `app/models/tenant.rb` — predicate + memoized class method
- `app/models/decision.rb` — delete `public?` stub at line 188
- `app/controllers/application_controller.rb` — bypass + macro
- `app/controllers/{notes,decisions,commitments}_controller.rb` — `allows_anonymous :show`, cache headers, rate limit
- `app/controllers/help_controller.rb` — `allows_anonymous(:index, *TOPICS)`, cache headers
- `app/views/help/privacy.md.erb` — deployment-aware rewrite
- `app/views/layouts/*` + partials per Phase 0 — suppress interaction surfaces
- New: `app/views/shared/_login_to_act.html.erb`
- New: `config/initializers/anon_readable_tenants.rb`
- `test/test_helper.rb` — `with_anon_readable_subdomains` helper
- Tests: `test/integration/anonymous_access_invariants_test.rb`, controller tests, `test/manual/anonymous_read_access.manual_test.md`, unit tests for the new methods + initializer
- E2E: `e2e/tests/anonymous_read_access.spec.ts`
- `.env.example`, `CHANGELOG.md`
- New plan: `.claude/plans/anonymous-read-audit-notes.md` (Phase 0; moves to completed/ on merge)

## Risks to verify during implementation

- **Default-scope leakage**: nothing in show paths calls `unscope_collective`, `tenant_scoped_only`, or `for_user_across_tenants`.
- **Single-tenant mode**: bypass works in both single- and multi-tenant configs.
- **Sorbet `typed: true`** on touched models; regenerate RBIs if needed.
- **CSRF**: gate enforces GET/HEAD only — non-GET can't reach the bypass.

## Decisions confirmed with the user

1. Anonymous reach is the three item URLs (`/n/:id`, `/d/:id`, `/c/:id`) plus `/help` and `/help/:topic`. Root path still 302s.
2. Private tenants stay 100% private — enforced by Phase 5 sweep.
3. All nested routes (participant pages, sub-routes) stay logged-in-only.
4. Public-tenant identification via dedicated `ANON_READABLE_TENANT_SUBDOMAINS` env var, default-deny.
5. Rate limiting ships inline (60 req/min per IP, 429 on excess).
6. Privacy doc is deployment-aware and FQDN-explicit.
7. No external comms — `CHANGELOG.md` entry only.
