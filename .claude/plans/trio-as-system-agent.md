# Trio as a System AI Agent

## Goal

Re-implement Trio as an ordinary `ai_agent` `User` in the existing AI agent system, with a special-case "system agent" flag so it can exist without a human parent and without billing. Keep `/trio` as a dedicated chat page with the trefoil logo, but have it use the existing agent chat plumbing (ChatSession, AiAgentTaskRun, agent-runner, ActionCable, `agent_chat_controller.ts`).

Delete everything from the old voting-ensemble experiment: the external Python service, the Ruby client, the bespoke chat controller, the aggregation methods, and all related env vars.

## Decisions (already made)

| Question | Answer |
|---|---|
| Scope | One trio User per tenant |
| `parent_id` for trio | Allow `nil` when the user is a system agent (new `system_role` string column on `users`; `system_role: "trio"` for trio, `nil` for ordinary users/agents) |
| Billing | System agents are billing-exempt (no `stripe_customer_id` required, no billing precondition in dispatch) |
| System prompt | Fresh static prompt stored in `trio_user.agent_configuration["identity_prompt"]` at seed time — `HarmonicAssistant` is no longer used and gets deleted |
| Logo | Keep the trefoil. Its "three loops = three models" meaning is gone, but it's just a logo now |

## Out of scope

- Parallel task runs for trio (future work — current `chat_session.task_runs.exists?(status: [queued, running])` guard stays).
- Any change to the user-created agent flow.
- Migrating existing trio chat history — there is none (current `/trio` is a Coming Soon placeholder).

---

## Phase 1 — Schema: `system_role` column on `users`

**Migration:** add a nullable string column `system_role` to `users`, indexed. Null for ordinary users and user-created agents; `"trio"` for the seeded trio user.

> Note: distinct from the existing `sys_admin` boolean column (from `HasGlobalRoles`, marks privileged **humans**). `system_role` is about **identity** (system-seeded non-human entity), not privilege. `user.system?` and `user.sys_admin?` are unrelated checks.

**`app/models/user.rb` changes:**
- Add `validates :system_role, inclusion: { in: %w[trio], allow_nil: true }`. Whitelist grows when new system roles are introduced.
- Add `def system? = system_role.present?` predicate. (And `def trio? = system_role == "trio"` if read sites want it.)
- Update `ai_agent_must_have_parent`: allow `parent_id` to be `nil` when `ai_agent? && system?`. Still require parent for non-system ai_agents. Still reject `parent_id` on humans.
- Skip the `after_create :create_parent_trustee_grant!` callback when `system?` (no parent to grant to).
- Add a `scope :system_agents, -> { where.not(system_role: nil) }` for future queries.

**Tests** (in `test/models/user_test.rb`):
- AI agent with `system_role: "trio"` can be created with `parent_id: nil`.
- Non-system ai_agent still requires a parent (existing test should still pass).
- No TrusteeGrant is created for a system ai_agent.
- `system_role` rejects unknown values.

---

## Phase 2 — Seed trio per tenant

**New service:** `app/services/trio_seeder.rb` with `TrioSeeder.ensure_for(tenant)`. Idempotent — finds-or-creates the trio user for the tenant.

What it creates:
- `User` with:
  - `user_type: "ai_agent"`
  - `system_role: "trio"`
  - `parent_id: nil`
  - `name: "Trio"`, `handle: "trio"` (or fall back if `trio` is taken in that tenant — unlikely, but guard)
  - `email: "trio-#{tenant.subdomain}@system.harmonic.local"` (synthetic, like other agent emails but stable per tenant)
  - `agent_configuration:` `{ "mode" => "internal", "model" => <default>, "identity_prompt" => TRIO_SYSTEM_PROMPT, "capabilities" => [...] }`

**Lookup:** `User.find_by(tenant: t, system_role: "trio")` (via TenantUser join — actual query lives in TrioSeeder). Independent of `handle`, so renaming trio's handle later wouldn't break gating.
- `TenantUser` linking trio to the tenant.
- `CollectiveMember` adding trio to the tenant's main collective (so chat session creation has a place to live).
- **No** `StripeCustomer`, **no** `ApiToken`, **no** `TrusteeGrant`.

**Where to call it:**
- Migration data step (backfill for existing tenants).
- Hook into wherever `Tenant` is created — find the existing place that sets up main collective / system records, and add `TrioSeeder.ensure_for(tenant)`.
- Expose a rake task `trio:reseed` that re-runs `ensure_for` and also refreshes `identity_prompt` from the static source (so prompt edits roll out without a migration).

**Static prompt:** lives at `app/services/trio/system_prompt.rb` as a frozen string constant (or a `.txt` file read at boot). Keep it short and concrete — Trio's role, tone, what it can help with, what it shouldn't do. Drafted separately; this plan doesn't lock the wording.

**Tests** (in `test/services/trio_seeder_test.rb`):
- `ensure_for(tenant)` creates one trio user, idempotent on second call.
- Trio user has `system_role: "trio"`, `parent_id: nil`, `mode: "internal"`, no stripe_customer.
- Trio is a member of the tenant's main collective.

---

## Phase 3 — Billing exemption in dispatch

**`app/services/agent_runner_dispatch_service.rb`:**
- The current billing check (`ai_agent.pending_billing_setup?`, `billing_customer&.active?`) needs to short-circuit when `ai_agent.system?`. Skip both the precondition and the cost-attribution payload.
- The Redis stream payload currently includes `stripe_customer_stripe_id`. For system agents, send `nil` (or omit) — confirmed safe per the agent-runner audit (see Resolved section).

**`app/models/ai_agent_task_run.rb`:**
- The `stripe_customer_id` snapshot at `create_queued` time: make it optional when the agent is `system?`. Validation if any needs to allow nil for system-agent runs.

**Tests:** update `test/services/agent_runner_dispatch_service_test.rb` with a system-agent case that dispatches successfully with no billing customer and no billing-related failure.

---

## Phase 4 — Route, controller, view

**Goal:** `/trio` renders a full-page chat with trio, using the existing chat partials and `agent_chat_controller.ts`, wrapped in trio-specific branding (trefoil logo header, page title).

**`app/controllers/trio_controller.rb`** — rewrite:
- Remove `create` action entirely.
- `index`:
  - Look up the tenant's trio user via `TrioSeeder.ensure_for(current_tenant)` (defensive — should always exist, but cheap to ensure).
  - Find/create the `ChatSession` between `current_user` and trio via `ChatSession.find_or_create_between`.
  - Assign `@chat_session`, `@partner` (trio), `@messages` etc. as needed.
  - Render `app/views/trio/index.html.erb`.

**`app/views/trio/index.html.erb`** — rewrite:
- Trefoil logo header (keep the existing `data-controller="trio-logo"` block, sized smaller than the current placeholder).
- Below it, render the same chat partial that `chats/show` renders (likely a `_messages` / `_chat_window` partial — find and reuse, don't copy-paste).
- Page wrapper attached to `agent_chat_controller` Stimulus controller, not `trio_chat_controller`.

**Routes:** keep `GET /trio`. Remove `POST /trio` (`chats_controller#send_message` already handles message POSTs at `/chat/:handle/message`).

**Feature flag:** keep the existing `trio` flag and the `trio_enabled?` gating on Tenant/Collective. `TrioController#index` still checks `current_tenant.trio_enabled?` (or collective-level if applicable) before rendering. Useful for staged rollout.

**Tests** (`test/controllers/trio_controller_test.rb`): rewrite from scratch.
- GET `/trio` renders the chat UI when signed in.
- GET `/trio` finds-or-creates the chat session with the tenant's trio user.
- Sending a message via `/chat/trio/message` (existing route) creates a chat_turn task run for trio (this is mostly covered by chats_controller tests already — add a single sanity case).

---

## Phase 5 — Delete the old trio stack

Files to delete:
- `app/services/trio_client.rb`
- `app/services/concerns/harmonic_assistant.rb` (orphan after we move to a static trio prompt)
- `app/javascript/controllers/trio_chat_controller.ts`
- `test/services/trio_client_test.rb`
- The aggregation-mode code paths in any view partials (none should remain after the controller rewrite, but grep for `aggregation_method`).

Files to **keep**:
- `app/javascript/controllers/trio_logo_controller.ts`
- `app/javascript/utils/trefoil_logo_3d.ts`, `trefoil_logo.ts`
- `app/views/trio/index.html.erb` (rewritten, not deleted)

Config to clean up:
- `docker-compose.yml`: remove the `trio` service block (lines 217–223). Profile `llm` no longer needs a trio service; agent-runner is the LLM path.
- `.env.example`: remove `TRIO_BASE_URL`, `TRIO_TIMEOUT`, `TRIO_MODELS`, `TRIO_SYSTEM_PROMPTS`, `TRIO_AGGREGATION_METHOD`, `TRIO_JUDGE_MODEL`, `TRIO_SYNTHESIZE_MODEL`. (None of these are needed once the external service is gone.)
- `config/feature_flags.yml`: **keep** the `trio` flag entry (used for staged rollout).
- `app/models/tenant.rb`, `app/models/collective.rb`: **keep** `trio_enabled?` methods (called by the new TrioController).
- `app/controllers/application_controller.rb` line 611: trio stays in `CONTROLLERS_WITHOUT_RESOURCE_MODEL` (the new trio controller still doesn't have a primary resource model).

Docs to update:
- `docs/ARCHITECTURE.md`: remove the TrioClient + external Trio service section; mention trio as a seeded system agent under the AI-agent architecture.
- Mark `.claude/plans/completed/2026/01/TRIO_PLAN.md` and `trio-aggregation-methods.md` as superseded — add a one-line note at the top pointing to this plan.

---

## Phase 6 — Verify end-to-end

Manual checks (also worth a generated manual-test doc under `test/manual/`):
1. Fresh tenant: `/trio` works immediately (TrioSeeder fires on tenant creation).
2. Existing tenant after migration: `/trio` works without re-seeding.
3. Sending a message to trio creates a chat_turn task run, runs in agent-runner, response streams back via ActionCable.
4. Trio does **not** appear on `/ai-agents` for any user — that list is already scoped to `current_user.ai_agents` (parent_id-based, confirmed in `AiAgentsController#index` line 16). Trio has `parent_id: nil`, so no filter change needed.
5. Billing is never charged for trio usage.
6. Trio is reachable at both `/trio` (with logo) and `/chat/trio` (plain chat UI) — both work; `/trio` is the canonical entry point.

---

## Open questions to confirm before implementing

1. **Trio's identity prompt content**: separate writing task, but should be drafted before seeding goes out.
2. **Stripe gateway behavior on unattributed requests**: in `stripe_gateway` LLM mode, the gateway may return 402 for requests without an `X-Stripe-Customer-ID` header. Confirm the gateway is configured to allow unattributed (system) requests, or trio runs will fail at the gateway even though agent-runner is fine. Not a code change in this repo — config on whatever fronts LiteLLM.

## Resolved

- Feature flag: **keep** `trio` flag and `trio_enabled?` gating for staged rollout.
- `/ai-agents` list: trio won't show up — list is already scoped to `current_user.ai_agents` (parent_id), and trio's parent is nil. No filter change needed.
- Default model: use `"default"` (whatever LiteLLM routes to) for now.
- **agent-runner billing**: confirmed pass-through. `stripe_customer_stripe_id` is fully optional in `TaskQueue.ts:43-89`; when absent, no `X-Stripe-Customer-ID` header is sent to LiteLLM. Tests already cover the `undefined` case. No agent-runner change needed for trio.

---

## Suggested implementation order

1. Phase 1 (schema + User changes) — small, isolated, testable.
2. Phase 2 (TrioSeeder + backfill migration) — depends on Phase 1.
3. Phase 3 (billing exemption) — depends on Phase 1.
4. Phase 5 cleanup of dead code (trio_client.rb, trio_chat_controller.ts, external service, env vars) — can land in parallel with Phase 2/3 since `/trio` will be temporarily broken anyway (it was just a placeholder).
5. Phase 4 (controller + view rewrite) — depends on Phase 2, 3, and the cleanup.
6. Phase 6 (verification + docs).

Each phase is a separate PR.
