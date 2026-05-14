# Trio Per-Collective Refactor (revised)

## Goal

Replace the single per-tenant Trio user with one Trio ai_agent **per
collective** that opted in (and per private workspace whose owner opted in).
Trio is wired into the system through the **existing automations** and
**existing mention-notification** infrastructure — no new triggering or
response mechanism is built. Each tenant admin / private-workspace owner
toggles a feature flag; turning it on materializes the trio user and seeds a
default automation. Trio can be customized like any other ai_agent thereafter.

## Why the previous draft was wrong

The earlier per-collective plan invented:
- a `TrioInvoker` service to dispatch tasks on `@`-mention,
- a new "respond by commenting" mechanism,
- and a special trio-only handling path on top of the mention parser.

All three duplicate features that already exist:
- **Automations** already trigger ai_agent task runs on events
  (note/comment/decision/commitment created), with a `mention_filter: "self"`
  trigger config that fires when the rule's agent is `@`-mentioned in the
  event's subject text. Agents are owned by their automations and run with
  their own identity.
- **Notifications** already deliver "you were mentioned" to any ai_agent
  user — same pipeline as for humans.
- **Comment creation** is already an action ai_agents can perform via
  `execute_action`. An automation task can tell trio "respond by commenting".

So this revision deletes ~70% of the previous plan's surface area.

## Decisions (already made)

| Question | Answer |
|---|---|
| Chat UI | None. No trio chat in this iteration. (Group chat for all collectives is future work, out of scope.) |
| How trio gets triggered | Existing automation system, `event` trigger + `mention_filter: "self"`. |
| How trio responds | Whatever the automation's task template says — most often "post a comment on the mentioning item". Trio uses the existing `execute_action` path. |
| Opt-in: collective | Collective admin toggles the existing `trio` feature flag in collective settings. On enable, trio user is created + default automations seeded. On disable, trio user + its automations are removed. |
| Opt-in: private workspace | Private workspaces are collectives too. Same flag, same UI affordance — though the "settings" page for a private workspace is owned by the user, not by admins. |
| `@trio` resolution | Trio's TenantUser gets a random hex handle (mirroring `collective_identity`). `MentionParser` gets a small special case: when `@trio` appears and the parser has a collective context, also include that collective's `trio_user` in the result. |
| Existing per-tenant trios | Deleted in the migration. Old ChatSessions / ChatMessages with the old per-tenant trio go too. |
| Default automations | Seeded when the flag is enabled. User-editable thereafter via the existing `CollectiveAutomationsController` and `AgentAutomationsController`. |

## Out of scope

- Per-collective customization of Trio's identity prompt (still one static `Trio::SystemPrompt.text` for every trio).
- Cross-collective "global" trio.
- Trio chat (per-collective or per-tenant).
- Group chat for collectives (separate future project).

---

## Phase 1 — Schema

**Migration:** `add_trio_user_id_to_collectives`
- Add `trio_user_id` (nullable foreign key to `users`, indexed). Mirrors the existing `identity_user_id` column.

**`Collective` model:**
- `belongs_to :trio_user, class_name: "User", optional: true, dependent: :destroy`

**Tests:** migration reversible, `Collective#trio_user` reads back the link.

---

## Phase 2 — Flag-driven seeding (collective)

**`TrioSeeder` rewrite:**
- Signature becomes `TrioSeeder.ensure_for(collective)`.
- If `collective.trio_user` already exists, return it (idempotent).
- Otherwise: create a `User` with `user_type: "ai_agent"`, `system_role: "trio"`, `parent_id: nil`, synthetic email; create a `TenantUser` with a random hex handle (the literal string `"trio"` is *not* the stored handle — the mention resolver handles the magic, see Phase 3); assign `collective.trio_user = trio`; save.
- Removed: per-tenant query, `add_user!` to main collective, `Tenant.set_thread_context` dance. None of those apply to per-collective trio.
- Removed: writing the identity_prompt into `agent_configuration` (Phase 5 of the previous plan already made it dynamic via `User#effective_identity_prompt`).

**New service:** `TrioActivator`
- `TrioActivator.activate!(collective)`:
  1. If a soft-deleted trio user exists for the collective, restore it + its soft-deleted automations and return. (Preserves admin customizations across off→on→off→on cycles.)
  2. Otherwise: `TrioSeeder.ensure_for(collective)` creates the trio user, then `seed_default_automations(collective.trio_user)` creates default `AutomationRule` rows owned by the trio user.
- `TrioActivator.deactivate!(collective)`:
  1. Soft-delete the trio user (set `archived_at` / `deleted_at` on User or equivalent — confirm which mechanism the codebase uses for ai_agents and AutomationRule in Phase 2). The trio user row + its `AutomationRule` rows remain in the DB so that re-enable can restore them.
  2. Null out `collective.trio_user_id`.

**Wiring into the feature flag toggle:**
- `CollectivesController#update_settings` already loops `FeatureFlagService.all_flags` and writes to `settings["feature_flags"][flag_name]`. After `save!`, detect the `trio` flag transitioning false→true or true→false (`saved_change_to_settings?` + before/after compare on the nested feature_flags hash), and call `TrioActivator.activate!/deactivate!` accordingly.

**Default automations to seed** (one per relevant trigger event, all enabled by default):
- `event` / `note.created`, `mention_filter: "self"`
- `event` / `comment.created`, `mention_filter: "self"`
- `event` / `decision.created`, `mention_filter: "self"`
- `event` / `commitment.created`, `mention_filter: "self"`

The actual *task template wording* for each rule is deferred to a separate drafting pass before Phase 2 commits — see Open Question #3. Templates use placeholders like `{{event.actor.name}}` and `{{subject.path}}` that the existing `AutomationTemplateRenderer` substitutes at dispatch time.

The collective admin can edit / disable / add more via the existing CollectiveAutomationsController UI after activation. On deactivate→reactivate, the admin's edits survive (see Open Question #2).

**No tenant-creation hook anymore** — Phase 5 of the prior implementation added `TrioSeeder.ensure_for(t)` to `AppAdminController#create_tenant` and `#execute_create_tenant`. Those calls are removed. Per-collective seeding is gated on opt-in, not tenant existence.

**Tests:**
- `TrioSeeder.ensure_for(collective)` creates a trio user with the right shape; idempotent on second call.
- `TrioActivator.activate!(collective)` creates trio + at least one automation; `deactivate!` removes them.
- Setting the `trio` flag to `true` via the controller invokes activation; setting to `false` invokes deactivation.
- Default automations have the right trigger/mention_filter configuration.

---

## Phase 3 — Per-private-workspace opt-in

Private workspaces are already collectives (`collective_type: "private_workspace"`), so the same flag/activator/deactivator works at the model layer. The UI is different:

- Private-workspace settings are owned by the user (the workspace's owner), not "collective admins" plural — but `CollectivesController#update_settings` already gates on collective-admin role, and the owner of a private workspace *is* the only admin. So the same controller path works.
- Add the `trio` feature flag toggle to the private-workspace settings view if it isn't already there. (The settings form is rendered for every collective type via the FeatureFlagService loop, so this might be free already — confirm in the view.)

**Tests:**
- Private workspace + `trio` flag enabled → user gets a private trio.
- Same activate/deactivate behavior.

---

## Phase 4 — `@trio` mention resolution

**`MentionParser` update**:
- `MentionParser.parse(text, tenant_id:)` keeps its existing behavior for arbitrary handles.
- Add an optional `collective:` kwarg. When supplied and the text contains `@trio`:
  - If `collective.trio_user` is present, include it in the result.
  - If `collective.trio_user` is nil, *don't* include anything in the result, but emit a one-shot side-effect notification to the mentioning actor: *"You mentioned @trio in {collective.name}, but Trio isn't enabled there. Enable it in collective settings."* (For non-admins: "Ask an admin to enable it.") This uses the existing `Notification` model and goes through normal channels.
- Trio's stored handle is random hex, so `@trio` never resolves to anything via the index — the magic happens here.

**`AutomationDispatcher` / `AutomationMentionFilter`:**
- `AutomationMentionFilter.matches?(event, ai_agent, mention_filter)` calls `MentionParser.parse(text, tenant_id:)`. Add the `collective:` kwarg, sourced from the event's subject (`event.subject.collective`, since notes/comments/decisions all have a `collective_id`).
- `NotificationDispatcher.handle_note_event` does the same — pass `collective:`.

After this, the existing automation pipeline does the rest:
- User writes `@trio …` in a comment inside Collective A.
- `EventService.record!` fires a `comment.created` event.
- `NotificationDispatcher` parses mentions with Collective A's context → A's trio user is in the mention list → A's trio gets a normal "you were mentioned" notification.
- `AutomationDispatcher` iterates rules; A's trio's "respond to comment mentions" rule has `mention_filter: "self"`, the filter passes, the rule fires, a task gets dispatched for trio. Trio runs.

**Tests:**
- `MentionParser.parse("hi @trio", tenant_id:, collective:)` includes the collective's trio user.
- Same parse with no `collective:` does not (and does not error).
- Same parse with a different collective resolves to *that* collective's trio.
- `MentionParser.parse("hi @trio", tenant_id:, collective:)` with `collective.trio_user` nil sends a notification to the actor and returns no trio mention.
- `AutomationMentionFilter.matches?` returns true for a trio agent when `@trio` is in the event's subject text in the trio's collective.

---

## Phase 5 — Tear down old per-tenant trio

Cleanup migration `remove_per_tenant_trio_users`:
- Destroy all existing per-tenant trio users (cascades to their ChatSessions / ChatMessages / AiAgentTaskRuns / etc.).
- Flagged in the migration body as intentionally destructive.

Files to delete:
- `app/controllers/trio_controller.rb`
- `app/views/trio/index.html.erb`
- `test/controllers/trio_controller_test.rb`
- `app/javascript/controllers/trio_logo_controller.ts`, `app/javascript/utils/trefoil_logo*.ts` (trefoil was branding for `/trio`; consider keeping if it'd be reused as trio's avatar somewhere — otherwise delete)
- Route `get 'trio' => 'trio#index'`

Files to update:
- `app/controllers/app_admin_controller.rb` — remove the `TrioSeeder.ensure_for(t)` calls in `#create_tenant` and `#execute_create_tenant`.
- `lib/tasks/trio.rake` — rewrite or delete (the per-tenant reseed concept doesn't apply; the static prompt is dynamic now). Probably just delete.
- `db/migrate/20260513000001_backfill_trio_for_existing_tenants.rb` doesn't need a counterpart undo migration; the `remove_per_tenant_trio_users` migration handles cleanup.
- `app/models/tenant.rb` `trio_enabled?` — keep or remove? The collective-level `trio_enabled?` is the one that matters going forward. Tenant-level might still gate "can collectives in this tenant enable trio at all" — useful kill switch. Keep.
- `docs/ARCHITECTURE.md` — refresh the Trio section.
- `.claude/plans/trio-as-system-agent.md` — already done; mark superseded by this plan.

Files to keep:
- `app/services/trio/system_prompt.{rb,md}` — same dynamic-prompt mechanism.
- `app/models/user.rb` `system_role`, `effective_identity_prompt`, `system?` — unchanged.
- `app/services/agent_runner_dispatch_service.rb` billing-exempt path — still applies to per-collective trios.

---

## Phase 6 — Verify end-to-end

Manual checks:
1. Fresh collective + trio disabled (default) → no trio user.
2. Collective admin toggles trio on in settings → trio user exists for that collective + default automations are visible in `/collectives/:handle/settings/automations`.
3. `@trio` in a comment in that collective → trio gets the mention notification + the automation fires + trio posts a comment in response.
4. `@trio` in a comment in a *different* collective (trio not enabled there) → resolves to nothing, no automation runs, mentioner gets a "Trio isn't enabled here" notification.
5. Two simultaneous `@trio` mentions in two different opted-in collectives → both run concurrently (different agents, different agent locks).
6. Two simultaneous `@trio` mentions in the *same* collective → serialize through the existing per-agent lock.
7. Collective admin toggles trio off → trio user and its automations are soft-deleted; `@trio` no longer resolves; subsequent re-enable restores the same trio user + any admin edits to its automations.
8. User enables trio in their private workspace settings → trio appears there, automations work.

---

## Open questions

These are real choices, but smaller than the previous plan's:

1. ~~**Activator-on-flag-flip vs. activator-on-callback.**~~ **Resolved: controller-side dispatch.** `CollectivesController#update_settings` detects the flag flip after `save!` and calls `TrioActivator.activate!/deactivate!` accordingly. Other write paths (Rails console, seed scripts, future controllers) call the activator explicitly rather than relying on a hidden callback side effect.

2. ~~**What happens to a collective's *user-edited* trio automations when trio is disabled and re-enabled later?**~~ **Resolved: archive on disable, restore on re-enable.** `TrioActivator.deactivate!` soft-deletes the trio user and its automations (preserves rows + customizations). `TrioActivator.activate!` restores soft-deleted trio + automations for that collective if found; otherwise creates fresh + seeds defaults. Needs an `archived_at` column or equivalent on `AutomationRule` if not already present — verify in Phase 2 and add a migration if missing.
3. **Default automation task templates** — still open. Wording shapes every trio response across every collective, so worth its own drafting pass before Phase 2 commits. Defer specifics; the *number* of defaults (one per relevant trigger event: note/comment/decision/commitment created with `mention_filter: "self"`) is fixed regardless.

4. ~~**`@trio` in a *non-opted-in* collective.**~~ **Resolved: notification to the mentioner.** When `MentionParser` is invoked with a collective context and the text contains `@trio` but `collective.trio_user` is nil, fire a one-shot notification to the mentioner: *"You mentioned @trio in #{collective.name}, but Trio isn't enabled there. Enable it in collective settings."* (Link goes to settings for admins; for non-admins, the message just tells them to ask an admin.) Uses the existing `Notification` model, no new infra. If it gets noisy in practice, rate-limit to one per mentioner-per-collective-per-day later.

## Suggested implementation order

1. Phase 1 (schema) — small.
2. Phase 4 (mention resolution) — small, isolated, useful even without trio being seeded yet (no-op for collectives without trio_user).
3. Phase 2 (seeder + activator + flag wiring) — depends on Phase 1.
4. Phase 3 (private workspace) — small, depends on Phase 2.
5. Phase 5 (delete old per-tenant surface) — destructive, but isolated.
6. Phase 6 (verify + docs).

Each phase is a separate commit (or PR), depending on how you want to ship.
