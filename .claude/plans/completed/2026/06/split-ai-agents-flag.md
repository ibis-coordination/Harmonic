# Split `ai_agents` Feature Flag

## Goal

**1. Split the flag.** Replace the single `ai_agents` feature flag with two independent flags so a tenant can enable external API-based agents without also enabling the internal Task Runner (and vice versa):

- `internal_ai_agents` — gates the Task Runner: agent-runner dispatch, automation execution, run UI.
- `external_ai_agents` — gates external API-token-based agents: their creation and the agent-management UI's external pathways.

The `api` flag stays as the gate on the API surface itself. The `trio` collective-level flag stays as the per-collective Trio toggle.

**2. Consolidate AI-agent UI.** AI-agent management is currently split across `/u/<handle>/settings` and `/ai-agents/<handle>/settings` with diverged-but-overlapping edit forms over the same `agent_configuration` JSONB. Collapse to a single canonical surface at `/ai-agents/<handle>/settings`. This expands scope but is worth doing now: without it, every conditional in the View-changes section has to be applied to both pages and kept in sync, and the duplicate write paths into `agent_configuration` would remain.

## Why

Today `ai_agents` conflates two distinct capabilities:

1. The **internal Task Runner** — an integrated service the deployment hosts, which dequeues tasks from Redis and runs agents on the operator's account (Trio rides on this path too).
2. **External AI agents** — User records with `agent_configuration["mode"] = "external"` that interact via REST + API tokens. They don't need the Task Runner at all.

The flag's current description already acknowledges the second category is gated only by `api`, but the controller, dispatcher, and nav code don't actually honor that distinction — turning `ai_agents` off hides external agents' management pages too. Tenants that want only external/API agents have to enable a flag that also stands up the internal Task Runner.

## Current behavior (audit results)

Only four production gate sites check `ai_agents_enabled?`:

| Site | What it gates today | Side |
|---|---|---|
| [tenant.rb:268](app/models/tenant.rb#L268) | The predicate itself | infra |
| [ai_agents_controller.rb:7,486-487](app/controllers/ai_agents_controller.rb#L486-L487) | `index, show, settings, run_task, execute_task, runs, show_run, cancel_run` | **mixed** (index/show/settings are shared across internal+external; runs/run_task are internal-only) |
| [automation_dispatcher.rb:14](app/services/automation_dispatcher.rb#L14) | All automation rule dispatch | internal |
| [agent_runner_dispatch_service.rb:28](app/services/agent_runner_dispatch_service.rb#L28) | Pushing tasks onto the `agent_tasks` Redis stream | internal |
| [_top_right_menu.html.erb:61-70](app/views/layouts/_top_right_menu.html.erb#L61-L70) | Both "Chat" and "AI Agents" nav links | **mixed** (chat works with external agents too) |

Internal vs external is already distinguished in the model:

- [user.rb:230-238](app/models/user.rb#L230-L238) — `internal_ai_agent?` ↔ `agent_configuration["mode"] == "internal"`; `external_ai_agent?` is the inverse.
- [agent_runner_dispatch_service.rb:37-40](app/services/agent_runner_dispatch_service.rb#L37-L40) — external agents are explicitly refused at dispatch.
- Trio is internal: [trio_seeder.rb:91](app/services/trio_seeder.rb#L91) seeds `"mode" => "internal"`.

`AiAgentsController` does *not* gate creation/update/deactivation today (only billing gates `new`). So today you can POST to create an agent with the flag off but you can't see the index.

## Scope

### Flag definitions ([config/feature_flags.yml](config/feature_flags.yml))

Remove `ai_agents`. Add:

```yaml
internal_ai_agents:
  name: "Internal AI Agents (Task Runner)"
  description: "Enables the Harmonic-managed Task Runner for executing internal AI agent runs (the agent-runner service, automation rule dispatch, and Trio's runtime path)."
  app_enabled: true
  default_tenant: false
  default_collective: false
  collective_level: false

external_ai_agents:
  name: "External AI Agents"
  description: "Allows users to create AI agents that interact with Harmonic via the API using API tokens. Requires the 'api' flag."
  app_enabled: true
  default_tenant: false
  default_collective: false
  collective_level: false
```

Migration path: existing tenants with `ai_agents` set (either value) get both new flags set to the same value, preserving behavior exactly. Feature flag values live in the `tenants.settings` JSONB column under `feature_flags.<flag_name>` ([has_feature_flags.rb:8-21](app/models/concerns/has_feature_flags.rb#L8-L21)) — there is no separate settings table. The migration is a `jsonb_set` on `tenants` mirroring the shape of [db/migrate/20260112131013_migrate_feature_flags_settings.rb](db/migrate/20260112131013_migrate_feature_flags_settings.rb):

```sql
-- For both new flags, copy the existing ai_agents value (or 'false' default), then delete the old key.
UPDATE tenants
SET settings = jsonb_set(
  settings,
  '{feature_flags,internal_ai_agents}',
  COALESCE(settings->'feature_flags'->'ai_agents', 'false'::jsonb),
  true
);
UPDATE tenants
SET settings = jsonb_set(
  settings,
  '{feature_flags,external_ai_agents}',
  COALESCE(settings->'feature_flags'->'ai_agents', 'false'::jsonb),
  true
);
UPDATE tenants
SET settings = settings #- '{feature_flags,ai_agents}';
```

The `collectives` (a.k.a. `studios`) table doesn't need migration since `ai_agents` is `collective_level: false` and never settable per-collective, but a defensive `#-` removal on `studios` is cheap and worth including in case any historical write put it there.

### Tenant predicates ([tenant.rb:268](app/models/tenant.rb#L268))

Replace `ai_agents_enabled?` with `internal_ai_agents_enabled?` and `external_ai_agents_enabled?`. Add a convenience `any_ai_agents_enabled?` (returns `internal || external`) for the shared management-page gate. No grace alias — the old method goes away.

### Controller gates ([ai_agents_controller.rb:7](app/controllers/ai_agents_controller.rb#L7))

Split the single `before_action :require_ai_agents_enabled` into two:

- `before_action :require_any_ai_agents_enabled, only: [:index, :show, :settings, :update_settings, :describe_update_ai_agent, :execute_update_ai_agent, :settings_actions_index]` — pages that manage agents of either type. **Behavior change:** today `update_settings` and the describe/execute update pair are ungated; this brings them under a gate. For tenants where the old `ai_agents` flag was on, the migration sets both new flags on and behavior is identical. For tenants where the old flag was off, agent self-update via the markdown API was reachable before and is now blocked — call this out in the CHANGELOG.
- `before_action :require_internal_ai_agents_enabled, only: [:run_task, :execute_task, :runs, :show_run, :cancel_run]` — Task-Runner-only actions.
- Creation (`new, create, execute_create_ai_agent`) — gate on whichever flag matches the **effective** mode. The new form ([new.html.erb:119](app/views/ai_agents/new.html.erb#L119)) defaults the radio to `internal`; the API helper ([api_helper.rb:728](app/services/api_helper.rb#L728)) defaults missing/invalid `params[:mode]` to `external`. These two defaults disagree; the gate code must resolve mode the same way the create path will (`["internal", "external"].include?(params[:mode]) ? params[:mode] : "external"`) so an absent param maps to the external gate. Keep the existing billing gate on `:new`. If neither flag is on, the `new` page itself should 403.
- `deactivate, reactivate` — leave ungated (you must be able to deactivate an existing agent even if the corresponding flag is turned off later).

### Service gates

- [automation_dispatcher.rb:14](app/services/automation_dispatcher.rb#L14) → `return unless event.tenant&.internal_ai_agents_enabled?`
- [agent_runner_dispatch_service.rb:28](app/services/agent_runner_dispatch_service.rb#L28) → `return unless tenant&.internal_ai_agents_enabled?`

Both are unambiguously internal — they implement Task Runner dispatch.

### View changes

The new flag combinations make several existing UI surfaces actively wrong (external-only tenants seeing internal-only affordances, empty-state copy assuming the Task Runner, etc.). The gates protect the routes; the views need to stop linking to gated routes and stop describing capabilities the tenant doesn't have. Concrete changes:

**1. Top nav ([_top_right_menu.html.erb:61-70](app/views/layouts/_top_right_menu.html.erb#L61-L70))**

- "AI Agents" link → wrap in `@current_tenant&.any_ai_agents_enabled?`.
- "Chat" link → unconditional. [chats_controller.rb](app/controllers/chats_controller.rb) has no AI-agent flag gating at all; humans chat regardless. The current coupling of Chat-link visibility to `ai_agents_enabled?` is purely cosmetic and should be removed entirely (don't replace it with `api_enabled?` — there's no semantic basis for that gate either).

**2. User Settings "AI Agents" accordion**

Deleted entirely by the consolidation work below (see "Consolidate AI-agent UI" → C4). No flag-gating needed because the accordion no longer exists.

**3. `/ai-agents/new` form ([ai_agents/new.html.erb:114-147](app/views/ai_agents/new.html.erb#L114-L147))**

The form must adapt to which modes the tenant has enabled:

- Both flags on → current behavior (mode radio with Internal default; Stimulus toggles model selector vs API-token checkbox).
- Only `internal_ai_agents` → hide the Mode section entirely; submit `mode=internal` via `hidden_field_tag`. The Model selector stays visible; the token-checkbox section is unreachable.
- Only `external_ai_agents` → hide the Mode section; submit `mode=external` via hidden field. The Model selector is hidden; the token-checkbox section is visible.
- Neither → the `:new` action 403s per the controller-gate plan, so the view never renders.

This sidesteps the form-vs-api-helper default disagreement noted earlier: in single-mode setups the form sends an explicit `mode`, so the helper's external-default never matters.

**4. Index page ([ai_agents/index.html.erb](app/views/ai_agents/index.html.erb))**

Three changes:

- **Per-agent action buttons (lines 86-96):** wrap "Run Task," "Runs," and "Automations" in `ai_agent.internal_ai_agent? && @current_tenant.internal_ai_agents_enabled?`. This fixes the *pre-existing* bug where external agents show those buttons (they currently lead to a doomed task or a never-firing automation rule), AND handles the new external-only tenant case in one shot.
- **Body copy (lines 33-38):** the static paragraphs assuming both modes are available need to be parameterized. Three variants:
  - Both: keep current ("AI Agents can be powered externally through the API or internally using Harmonic's agent runners").
  - Internal only: "AI Agents are powered by Harmonic's agent runners and can run automated tasks on your behalf."
  - External only: "AI Agents are powered by your own infrastructure and interact with Harmonic through the API."
- **Empty state (lines 116-126):** the current "Create an AI Agent to start running automated tasks" assumes internal. Parameterize the same way as the body copy. Internal-only keeps the current copy; external-only becomes "Create an AI Agent to give programmatic access to the API"; both gets a more general phrasing.

**5. Show page ([ai_agents/show.html.erb:95-113](app/views/ai_agents/show.html.erb#L95-L113))**

Same gate as index for the action-row buttons: wrap "Run Task" and "Automations" in `@ai_agent.internal_ai_agent? && @current_tenant.internal_ai_agents_enabled?`. Leave "Chat," "Settings," "View Profile" unconditional.

Also: the "Recent Task Runs" section ([show.html.erb:167+](app/views/ai_agents/show.html.erb#L167)) and the "Automations" section block only render if those collections are non-empty, so they degrade gracefully for external agents already — no change needed beyond hiding the "Create Automation" CTA for external agents (currently always shown when `@automation_rules` is empty). Wrap that CTA in the same `internal_ai_agent? && internal_ai_agents_enabled?` check.

**6. `run_task` view ([ai_agents/run_task.html.erb](app/views/ai_agents/run_task.html.erb))**

This is reachable only when `internal_ai_agents_enabled?` (per the controller gate), but the controller doesn't currently check `@ai_agent.internal_ai_agent?` — an external agent on an internal-enabled tenant can still hit this page via a direct URL. Add an early return in `AiAgentsController#run_task` and `#execute_task`:

```ruby
return render status: :not_found, plain: "404 Not Found" unless @ai_agent.internal_ai_agent?
```

This closes a pre-existing UX bug (form → submission → failed run with "cannot dispatch external agents") and is mechanically trivial.

**7. `agent_automations_controller`**

Automations only fire via `AutomationDispatcher` → `AgentRunnerDispatchService`, both of which now gate on `internal_ai_agents_enabled?`. Authoring an automation rule on an external agent, or on any agent when the internal flag is off, produces a rule that will never execute. Gate the controller:

- Add `before_action :require_internal_ai_agents_enabled` to all actions (use the same predicate as `AiAgentsController`, refactored into a shared concern or duplicated — pick during implementation based on how many controllers will need it).
- Inside the per-agent automations actions, also reject if `@ai_agent.external_ai_agent?`.

Confirm by reading the actual controller during implementation — the grep showed it exists but I didn't audit its before_action chain.

### Consolidate AI-agent UI into `/ai-agents`

The flag-split is the right moment to also collapse a pre-existing UI duplication: AI-agent management is currently split across `/u/<handle>/settings` and `/ai-agents/<handle>/settings`, both rendering edit forms over the same `agent_configuration` JSONB. Without this consolidation, every conditional in the "View changes" section above has to be applied to both pages, and the two would have to be kept in sync indefinitely.

**Diverged duplication today:**

- `/u/<agent>/settings` ([users/settings.html.erb:52-148](app/views/users/settings.html.erb#L52-L148)) → editable Mode radio, Model (conditional), Identity Prompt, full Capabilities checkbox grid. POSTs to `UsersController#update_profile`.
- `/ai-agents/<agent>/settings` ([ai_agents/settings.html.erb:61-82](app/views/ai_agents/settings.html.erb#L61-L82)) → editable Model (only if internal), Identity Prompt. **No Mode toggle. No Capabilities.** POSTs to `AiAgentsController#update_settings`.
- Both write paths accept and write to the same fields ([users_controller.rb:264-296](app/controllers/users_controller.rb#L264-L296) handles mode/model/capabilities/identity_prompt; [ai_agents_controller.rb:114-119](app/controllers/ai_agents_controller.rb#L114-L119) does the same).
- API tokens for AI agents appear in *both* the human's `/u/<self>/settings` aggregate table ([users/settings.html.erb:298-365](app/views/users/settings.html.erb#L298-L365)) and on each per-agent settings page ([ai_agents/settings.html.erb:122-178](app/views/ai_agents/settings.html.erb#L122-L178)).

**Target: `/ai-agents/<handle>/settings` is the single canonical management surface for an AI agent.** `/u/<agent>/settings` for an AI agent stops being a parallel edit page.

**Concrete changes:**

**C1. Move the missing form sections into `/ai-agents/<handle>/settings`.**

[ai_agents/settings.html.erb](app/views/ai_agents/settings.html.erb) absorbs from [users/settings.html.erb](app/views/users/settings.html.erb):
- The Mode radio + Stimulus controller for show/hide of Internal/External-specific sections (lines 52-81 of users/settings).
- The Capabilities checkbox grid (lines 89-148 of users/settings), including the action_groups Hash, the `disabled_by_default` list, and the `checkbox-group` Stimulus targets.

Apply the View-changes rules from item 3 (Mode radio hidden when only one flag is enabled, with a hidden field carrying the right value) here, not in the original location.

**C2. Single canonical surface at `/ai-agents/<handle>/settings`; `/u/<agent>/settings` redirects there.**

`UsersController#settings` redirects to `ai_agent_settings_path(@settings_user.handle)` when `@settings_user.ai_agent?` (both HTML and MD). The audit confirmed that almost every section in user-settings is already gated invisible for agents (email/2FA/billing/blocked-users/Workspace-Trio are all under `is_own_settings && human?`). The only thing genuinely unique to user-settings was the profile-image upload, which moves to `/ai-agents/<handle>/settings`.

After this change, agents have one canonical settings surface. No cross-links needed — the redirect makes them invisible from the user-settings URL.

**C3. Loosen authorization on read paths so the agent itself can read its own settings.**

[ai_agents_controller.rb:11](app/controllers/ai_agents_controller.rb#L11) currently applies a single `authorize_parent` before_action to *all* show/settings/update/deactivate/reactivate actions, restricting to `@ai_agent.parent_id == current_user.id`. The agent should be able to read its own settings (so it can introspect via `/ai-agents/<self>/settings.md`) but not edit them.

Split the gate. Replace the single `before_action :authorize_parent, only: [...]` with two:

```ruby
before_action :authorize_parent_or_self, only: [:show, :settings, :settings_actions_index]
before_action :authorize_parent, only: [:update_settings, :execute_update_ai_agent, :describe_update_ai_agent, :deactivate, :reactivate]

def authorize_parent_or_self
  return if @ai_agent.parent_id == current_user&.id
  return if @ai_agent == current_user
  render status: :forbidden, plain: "403 Unauthorized"
end
```

`authorize_parent` itself stays unchanged. Test that a non-parent, non-self user still 403s on read paths.

**C4. Remove the "AI Agents" link accordion.**

[users/settings.html.erb:442-455](app/views/users/settings.html.erb#L442-L455) is pure navigation; the top nav already provides this entry point. Delete the accordion. The markdown equivalent at [users/settings.md.erb:51](app/views/users/settings.md.erb#L51) (`* [Manage AI Agents](/ai-agents)`) stays — markdown UI relies on inline links for navigation.

**C5. Split the API Tokens accordion in `/u/<self>/settings`.**

The aggregate view at [users/settings.html.erb:296-365](app/views/users/settings.html.erb#L296-L365) shows the human's own tokens AND every AI agent's tokens. Per-agent token management is already on the per-agent settings page; the aggregate view is the only place that lists everything together.

Two options, pick during implementation:
- **(a) Filter to the human's own tokens.** `@all_api_tokens` becomes the user's personal tokens only; agents' tokens are managed solely on their own pages. Helper text drops the "this includes tokens for your AI agents" line. Cleanest split, loses the aggregate.
- **(b) Keep the aggregate, but link rows for AI agents to the per-agent settings page** instead of inline token management. The table becomes a read-only at-a-glance view; the "View" link goes to `/ai-agents/<handle>/settings#tokens`. Preserves the aggregate as a discovery aid.

(a) is the strict consolidation; (b) trades a tiny duplication for a useful aggregate. Default to (a) and ship (b) if and when someone misses the aggregate.

**C6. Remove vestigial agent-config branches from `UsersController#update_profile`.**

Once the form at [users/settings.html.erb:52-148](app/views/users/settings.html.erb#L52-L148) is gone, [users_controller.rb:264-296](app/controllers/users_controller.rb#L264-L296) (which handles `identity_prompt`, `mode`, `model`, `capabilities` for AI agents) becomes dead code. Remove.

The documented `update_profile` markdown action is `name + new_handle` only ([actions_helper.rb:503-511](app/services/actions_helper.rb#L503-L511)) — these branches were accidental form-handling, not part of the public markdown contract, so removing them breaks no documented agent self-update path. Agent config edits flow exclusively through `AiAgentsController#execute_update_ai_agent` and the corresponding markdown action.

**Out of scope (mention in plan, don't do):**

- **Workspace AI Assistant accordion** ([users/settings.html.erb:157-209](app/views/users/settings.html.erb#L157-L209)) — this is a Trio toggle for the user's private workspace, exposed in user settings because `CollectivesController#settings` redirects workspace owners away (per the in-file comment at line 158-160). It's a workspace setting that happens to live here for routing reasons, not an AI-agent setting. Moving it would require also fixing the collective-settings redirect. Leave it for a future "workspace settings consolidation" plan.

**Other entry points to `/u/<agent>/settings` to audit during implementation:** the user's own profile page ([users/show.html.erb](app/views/users/show.html.erb)) likely has a "Settings" link for own-agents; the chat partner sidebar may surface settings links; the `/ai-agents` index has a `View Profile` link to `/u/<handle>` (the profile page itself isn't affected, only the settings sub-route). The C2 redirect handles bookmarks transparently, but check that no internal link is constructed in a way that breaks (e.g., a `link_to` that bypasses the redirect by hand-rolling `/u/...`).

### Trio interaction (explicitly out of scope, but document the consequence)

Trio is an internal agent and rides the internal dispatch path. After this change Trio requires `internal_ai_agents` (tenant) + `trio` (collective). If `internal_ai_agents` is off, Trio cannot run regardless of the `trio` flag. This matches today's behavior (`trio` already requires `ai_agents` transitively through the dispatcher). No change to Trio code in this plan.

A future plan could make Trio exempt from `internal_ai_agents` the same way it's exempt from billing. The shape is non-trivial: `AutomationDispatcher.dispatch` takes an `Event` and only later discovers which `ai_agent_id` rules match, so the bypass has to live per-rule inside `find_matching_rules` (allow Trio's rules through even when the flag is off) and then again in `AgentRunnerDispatchService#dispatch` (skip the flag check when `ai_agent.system_role == "trio"`). Out of scope here — flagged so it isn't underestimated later.

### Decision: runtime API gating for external agents

The plan as written gates `external_ai_agents` only at **creation** and **management UI**. It does *not* gate the API request authentication path. Consequence: turning the flag off prevents new external agents from being created, but existing external agents with valid API tokens continue to authenticate and act through the API (subject to the existing `api` flag).

This is the intentional choice because:

1. The `api` flag is the existing, well-understood gate on "external programmatic access works here." Adding a second AND-gate on the same auth path duplicates that concern with no new product semantics.
2. "Disabling external AI agents" most commonly means "stop the proliferation of new ones," not "instantly revoke every existing agent." Operators who want the revoke semantic can deactivate individual agents, or disable `api` entirely.
3. The Task Runner gate (`internal_ai_agents` at the dispatcher / runner) genuinely is a runtime gate because it controls a Harmonic-operated service; external agents have no equivalent Harmonic-operated runtime to gate.

If a future need arises ("kill switch for all external agents on a tenant without taking down its human-driven API integrations"), add a check in the API token authentication path (probably `ApiToken#authenticate` or the API auth middleware — read before implementing) that rejects tokens whose owning User is an external AI agent on a tenant where `external_ai_agents` is off. That is an additive change, doesn't affect this plan, and shouldn't be done speculatively.

### Things explicitly NOT changing

- `api` flag — semantics unchanged.
- `User#internal_ai_agent?` / `external_ai_agent?` — already correct.
- `CapabilityCheck` / `ActionCapabilityCheck` — key off `User#ai_agent?`, not the flag. No change.
- Billing/suspension paths ([stripe_service.rb](app/services/stripe_service.rb), [billing_reconciliation_job.rb](app/jobs/billing_reconciliation_job.rb)) — gated on `stripe_billing`, not on `ai_agents`. No change.
- API token issuance / API auth — already on the `api` flag.

## Test changes

The grep showed ~50+ test files reference `ai_agents`. Most of those are testing AI-agent behavior (model tests, integration tests for runs, etc.) and only incidentally mention the flag name. The mechanical changes:

- Tests that call `tenant.enable_feature_flag!("ai_agents")` / `tenant.set_feature_flag!("ai_agents", true)` ([has_feature_flags.rb:23-39](app/models/concerns/has_feature_flags.rb#L23-L39)) need to pick the right new flag. Audit by test:
  - Tests exercising run dispatch, automation rules, Trio runtime → `internal_ai_agents`.
  - Tests exercising external-agent creation, API-token-based agent flows → `external_ai_agents`.
  - Tests exercising the management UI's index/show/settings → both flags (or use the `any_ai_agents_enabled?` helper).
- Add new gate-site tests:
  - `internal_ai_agents` off + `external_ai_agents` on → can create/manage external agents, can't dispatch via agent-runner, can't run a task.
  - `internal_ai_agents` on + `external_ai_agents` off → Task Runner works for existing internal agents, can't create new external agents.
  - Both off → management UI 403s on `index`; nav items hidden; user-settings AI Agents accordion hidden.
- Add view-level tests for the new conditional rendering:
  - Index page action buttons hidden for external agents (covers both pre-existing bug and external-only case).
  - `/ai-agents/new` form hides the Mode radio in single-mode tenants and submits a hidden `mode` field with the right value.
  - Empty-state and body copy match the enabled-flags combination.
- `AiAgentsController#run_task` / `#execute_task` should 404 for external agents (new behavior — closes pre-existing bug).
- `agent_automations_controller` actions 403 when `internal_ai_agents` is off, and 404/403 when the agent is external.
- Consolidation tests:
  - GET `/u/<agent>/settings` (HTML and MD) redirects to `/ai-agents/<handle>/settings(.md)` when `@settings_user.ai_agent?`.
  - GET `/ai-agents/<handle>/settings` includes the profile-image upload (the only piece previously unique to user-settings).
  - `UsersController#update_profile` (per C6) no longer mutates `agent_configuration` (mode/model/capabilities/identity_prompt branches removed). Posting those params via `/u/<agent>/settings/profile` is a no-op for those fields; only `name` and `new_handle` apply.
  - `/ai-agents/<handle>/settings` now renders the Mode radio (when both flags on) and Capabilities checkboxes; POSTing those fields updates `agent_configuration` correctly.
  - `authorize_parent` loosening: the agent itself can GET `/ai-agents/<self>/settings(.md)`; cannot POST `update_settings`. A non-parent, non-self user still 403s.
- Specifically test the Trio-internal coupling: with `trio` collective flag on but `internal_ai_agents` tenant flag off, Trio does not dispatch. This locks in the documented behavior.

Per CLAUDE.md and saved feedback ([feedback_red_green_tdd.md](memory)): write the gate-site tests first, watch them fail with the rename, then implement.

## Rollout

1. Land the YAML + tenant predicate + controller + service + view changes in one PR.
2. Data migration to copy `ai_agents` → `internal_ai_agents` AND `external_ai_agents` for every tenant that has it set (whether `true` or `false`), then remove the old key. Run-once (not idempotent — the third statement deletes `ai_agents`, so a hypothetical second run would COALESCE-default both new flags back to `false`). Rails' standard `schema_migrations` tracking is the correctness story here; the migration shouldn't be marked `safety_assured` or otherwise made re-runnable.
3. Remove `ai_agents` from the YAML in the same PR; the data migration handles the cutover.
4. CHANGELOG entry describing: (a) the flag split + migration semantics; (b) the consolidation — agent-specific configuration is now managed at `/ai-agents/<handle>/settings`, with cross-links to the user-type-agnostic settings at `/u/<handle>/settings`; (c) the closed pre-existing bugs — `run_task` is no longer reachable for external agents (was producing dead-end failed runs).

**Deploy-window note:** between the new code starting up and the migration completing, `tenant.internal_ai_agents_enabled?` will return the YAML default (`false`) for tenants whose new keys haven't been written yet, briefly disabling agent features for tenants that previously had `ai_agents` on. For Harmonic's single-instance deploy this window is short (one `UPDATE tenants` of a JSONB column) and acceptable. If the window matters, a two-step rollout (ship the migration first, then ship the code change) avoids it — but that requires the migration to write keys the running code doesn't yet read, which is harmless.

Otherwise no staged rollout needed — the migration preserves every tenant's current capability set exactly.

## Open questions to confirm during implementation

- Does any fixture or seed file write `ai_agents` directly into `tenants.settings`? Grep `db/seeds*` and `test/fixtures/` — the migration handles arbitrary tenant data but fixture data may need its own update for tests to load correctly.
- Is there a tenant-admin UI that lists feature flag names verbatim (e.g., a settings panel rendering `FeatureFlagService.all_flags`)? The split changes the displayed label/description; copy-check any such UI.
- The app-admin `show_user.html.erb` and `collectives/settings.{html,md}.erb` view files reference `ai_agents` per the earlier grep — confirm whether those are flag-related text or unrelated occurrences (e.g., listing a user's agents) before assuming they need updating.
- Consolidation: are there existing tests covering `UsersController#update_profile`'s mode/model/capabilities/identity_prompt branches that will break when those branches are removed? Update them to assert the no-op behavior or delete if they only existed to cover the removed code.
- Consolidation: does the user profile page ([users/show.html.erb](app/views/users/show.html.erb)) link to `/u/<handle>/settings` for the page owner? If so, for AI agents that link should either go directly to `/ai-agents/<handle>/settings` or rely on the C2 redirect — pick during implementation.
