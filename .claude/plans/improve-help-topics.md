# Plan: Improve In-App Help Topics

## Context

The in-app help system at `/help` currently has 14 topics. Several significant features have no help coverage at all, the index page is a flat list, and some help topics describe features that are gated behind feature flags — so users see a help link for something they can't actually use. We need to add missing topics, reorganize the index, retire the parallel `/learn` system, and gate feature-flagged topics behind their flags.

## Current State

**Existing topics (14):** privacy, collectives, notes, reminder_notes, table_notes, decisions, executive_decisions, lottery_decisions, commitments, cycles, search, links, agents, api

**Controller:** [app/controllers/help_controller.rb](app/controllers/help_controller.rb) — defines `TOPICS` array, dynamically generates routes/actions
**Content:** [app/views/help/](app/views/help/) — markdown with ERB (`{topic}.md.erb`)
**Routes:** [config/routes.rb:158-161](config/routes.rb#L158-L161) — `/help` index + `/help/{topic}` (mirrors TOPICS)
**Tests:** [test/integration/help_pages_test.rb](test/integration/help_pages_test.rb)
**Tenant context:** `current_tenant` is set as a before_action in [app/controllers/application_controller.rb:9](app/controllers/application_controller.rb#L9) and is available in the help controller and views.

## Feature Flag System

Feature flags are defined in [config/feature_flags.yml](config/feature_flags.yml) and checked via [app/services/feature_flag_service.rb](app/services/feature_flag_service.rb). The cascade is app → tenant → collective.

The convenient check from the help controller is `current_tenant.feature_enabled?("flag_name")`. Some flags have shortcut methods: `current_tenant.api_enabled?`, `current_tenant.ai_agents_enabled?`, `current_tenant.file_attachments_enabled?`, `current_tenant.trio_enabled?`.

**Existing flags:** `api`, `file_attachments`, `trio`, `ai_agents`, `stripe_billing`, `vote_receipt_emails`, `collective_export`, `user_data_export`.

### Topic ↔ Flag Mapping

| Topic | Feature Flag | Notes |
|-------|-------------|-------|
| `api` | `api` | Existing topic, currently shown unconditionally |
| `agents` | `ai_agents` | Existing topic, currently shown unconditionally |
| `billing` (new) | `stripe_billing` | New topic to add |
| `attachments` (folded into notes) | `file_attachments` | If we expand notes to cover attachments, gate that section |
| All others | none | reminder_notes, table_notes, executive_decisions, lottery_decisions, automations, webhooks, notifications, representation, settings, etc. are NOT feature-flagged |

## Gap Analysis

### Missing Topics (no help page exists)

| Feature | Coverage Gap | Source |
|---------|-------------|--------|
| **Automations** | Major feature with no help page. Full docs at [docs/AUTOMATIONS.md](docs/AUTOMATIONS.md). | [app/controllers/agent_automations_controller.rb](app/controllers/agent_automations_controller.rb), [app/controllers/collective_automations_controller.rb](app/controllers/collective_automations_controller.rb) |
| **Webhooks** | Incoming webhooks (external systems triggering automations) have no help page. | [app/controllers/incoming_webhooks_controller.rb](app/controllers/incoming_webhooks_controller.rb) |
| **Notifications** | No help page. Inbox, dismissing, reminders. | [app/controllers/notifications_controller.rb](app/controllers/notifications_controller.rb) |
| **Billing** | No help page. Subscriptions, per-identity pricing, credit topups. | [app/controllers/billing_controller.rb](app/controllers/billing_controller.rb) |
| **Representation & Trustees** | Briefly mentioned in collectives, but trustee grants and representation sessions have no dedicated coverage. | [app/controllers/trustee_grants_controller.rb](app/controllers/trustee_grants_controller.rb), [app/controllers/representation_sessions_controller.rb](app/controllers/representation_sessions_controller.rb) |
| **Settings / Profile / 2FA** | No help page. Handle, avatar, 2FA setup, API tokens. | [app/controllers/users_controller.rb](app/controllers/users_controller.rb) |
| **Comments** | One-sentence mention in notes. Threading, replies, where comments can be posted. | Part of notes/decisions/commitments |
| **Attachments** | No mention. (Feature-flagged on `file_attachments`.) | `Attachable` concern |
| **Pinning** | No mention. | `Pinnable` concern |
| **Content Reporting** | No mention. | Moderation controllers |

### Existing Topics with Thin Coverage

| Topic | What's Missing |
|-------|---------------|
| **API** | 38 lines, 4 example endpoints. Missing full endpoint list, correct scopes (read/create/update/delete, not just read/write), error handling, rate limits, pagination, include params. |
| **Agents** | No mention of automations (primary way agents act autonomously), task runs, agent billing. |
| **Collectives** | No mention of invitations workflow, adding AI agents, enabling API access, collective automations, heartbeat requirement, collective identity user. |
| **Notes** | No mention of attachments, pinning, links/backlinks from notes, deadlines, content reporting. (Subtypes now have their own pages.) |

### Index Organization

Current index is a flat list of 10 items (subtype pages reminder_notes/table_notes/executive_decisions/lottery_decisions exist but aren't yet linked from the index). It needs categorical grouping as more topics are added.

## Remove Stale Learn Pages

The `/learn` section is a separate set of conceptual explainer pages that predates the help system. These should be retired — their content merged into help pages where useful, and all references updated.

**Note:** `/motto` is its own route (`motto#index`, [config/routes.rb:195](config/routes.rb#L195)) with its own controller — completely independent of the learn system. It is linked in the application layout footer and **must NOT be touched**. The learn index merely linked to it.

### Learn Pages Inventory

| Page | Content Summary | Merge Target |
|------|----------------|--------------|
| `/learn` (index) | Links to all learn pages + `/motto` | Remove entirely (help index replaces it) |
| `/learn/awareness-indicators` | Confirmed reads as awareness signals for group coordination | Merge into `help/notes` — expand "Confirming Read" section with this framing |
| `/learn/acceptance-voting` | Acceptance voting as a negotiation-oriented method | Merge into `help/decisions` — add "why" framing |
| `/learn/reciprocal-commitment` | Conditional commitment with critical mass (Kickstarter for participation) | Merge into `help/commitments` — add "why" framing |
| `/learn/ai-agency` | Parent responsibility and visible accountability for AI agents | Merge into `help/agents` — add accountability section |
| `/learn/superagency` | Collectives acting as unified agents through representation | Merge into `help/representation` (new) |
| `/learn/memory` | Route exists but **no content file** — currently 404s | Remove entirely |

### References to Update

3 tooltip partials link to learn pages and need URL updates:
- [app/views/notes/_awareness_indicators_tooltip.html.erb](app/views/notes/_awareness_indicators_tooltip.html.erb) → `/help/notes#confirming-read`
- [app/views/decisions/_acceptance_voting_tooltip.html.erb](app/views/decisions/_acceptance_voting_tooltip.html.erb) → `/help/decisions#how-acceptance-voting-works`
- [app/views/commitments/_reciprocal_commitment_tooltip.html.erb](app/views/commitments/_reciprocal_commitment_tooltip.html.erb) → `/help/commitments#how-critical-mass-works`

### Files to Remove
- [app/controllers/learn_controller.rb](app/controllers/learn_controller.rb)
- [app/views/learn/](app/views/learn/) (entire directory)
- [test/controllers/learn_controller_test.rb](test/controllers/learn_controller_test.rb)
- Learn routes from [config/routes.rb:188-194](config/routes.rb#L188-L194)
- Any learn-related entries in [test/integration/markdown_ui_test.rb](test/integration/markdown_ui_test.rb)

## Proposed Changes

### 1. New Help Topics to Add

**Priority 1 — Major missing features:**
- `automations` — Condensed version of [docs/AUTOMATIONS.md](docs/AUTOMATIONS.md) for in-app consumption. Both agent and collective automations, trigger types, basic YAML examples. Link to full docs for schema reference.
- `webhooks` — Incoming webhook endpoints, HMAC verification, IP allowlists. (Could be a section of `automations` rather than its own topic — decide during writing.)
- `notifications` — Inbox, dismissing, reminders.
- `billing` — Pricing model, subscriptions, credits, identity-based pricing. **Feature-flagged: `stripe_billing`.**

**Priority 2 — Important supporting features:**
- `representation` — Trustee grants, representation sessions, collective agency in practice. Absorbs content from `/learn/superagency`.
- `settings` — User profile, 2FA, API tokens, account management.

**Priority 3 — Fold into existing pages rather than new topics:**
- Expand `notes` to cover attachments (gated), pinning, deadlines, content reporting, and absorb `/learn/awareness-indicators`
- Expand `agents` to mention automations, task runs, billing, and absorb `/learn/ai-agency`
- Expand `collectives` to mention invitations, adding agents, enabling API, collective automations
- Expand `decisions` with the "why" content from `/learn/acceptance-voting`
- Expand `commitments` with the "why" content from `/learn/reciprocal-commitment`
- Expand `api` with full endpoint list, correct scopes, pagination

### 2. Feature Flag Gating

Apply gating in two places:

**Help index** ([app/views/help/index.md.erb](app/views/help/index.md.erb)) — wrap feature-flagged links in conditionals so they don't show when disabled:

```erb
<% if current_tenant.feature_enabled?("api") %>
- [API](/help/api) — Programmatic access via tokens and REST
<% end %>
<% if current_tenant.feature_enabled?("ai_agents") %>
- [Agents](/help/agents) — AI agents that navigate and act in Harmonic
- [Automations](/help/automations) — Event-driven and scheduled workflows
<% end %>
<% if current_tenant.feature_enabled?("stripe_billing") %>
- [Billing](/help/billing) — Subscriptions, credits, and pricing
<% end %>
```

**Topic action methods** ([app/controllers/help_controller.rb](app/controllers/help_controller.rb)) — refactor so feature-gated topics check the flag and 404 if disabled:

```ruby
FEATURE_GATED_TOPICS = {
  "api" => "api",
  "agents" => "ai_agents",
  "automations" => "ai_agents",  # automations require ai_agents
  "billing" => "stripe_billing",
}.freeze

TOPICS.each do |topic|
  define_method(topic) do
    flag = FEATURE_GATED_TOPICS[topic]
    if flag && !current_tenant.feature_enabled?(flag)
      redirect_to "/404" and return
    end
    # ... existing rendering
  end
end
```

For sub-sections within a topic that are feature-gated (e.g., attachments inside `notes`), use ERB conditionals inline:

```erb
<% if current_tenant.feature_enabled?("file_attachments") %>
## Attachments
...
<% end %>
```

### 3. Reorganize the Index with Categories

```
## Getting Started
- Privacy
- Collectives
- Settings

## Content
- Notes
  - Reminder Notes
  - Table Notes
- Decisions
  - Executive Decisions
  - Lottery Decisions
- Commitments
- Cycles
- Search
- Links

## Automation & Integration  (gated where applicable)
- Agents (ai_agents flag)
- Automations (ai_agents flag)
- API (api flag)
- Notifications

## Account
- Billing (stripe_billing flag)
- Representation
```

Sub-topics like Reminder Notes can be nested or shown as indented list items in the index.

### 4. Implementation Steps (per topic)

1. Add topic name to `TOPICS` in [app/controllers/help_controller.rb](app/controllers/help_controller.rb)
2. Add corresponding route entry in [config/routes.rb:159](config/routes.rb#L159)
3. Add to `FEATURE_GATED_TOPICS` if applicable
4. Create [app/views/help/{topic}.md.erb](app/views/help/) with content
5. Add link to [app/views/help/index.md.erb](app/views/help/index.md.erb) (gated if applicable)
6. Update [test/integration/help_pages_test.rb](test/integration/help_pages_test.rb) — add coverage for the new topic AND for feature-flag gating behavior

### 5. Files to Modify

- [app/controllers/help_controller.rb](app/controllers/help_controller.rb) — add new topic names, add `FEATURE_GATED_TOPICS` constant and gating logic
- [config/routes.rb](config/routes.rb) — mirror new topic list, remove learn routes
- [app/views/help/index.md.erb](app/views/help/index.md.erb) — reorganize into categories, gate feature-flagged links
- [app/views/help/notes.md.erb](app/views/help/notes.md.erb) — expand; absorb `/learn/awareness-indicators`; gate attachments section
- [app/views/help/agents.md.erb](app/views/help/agents.md.erb) — expand; absorb `/learn/ai-agency`
- [app/views/help/collectives.md.erb](app/views/help/collectives.md.erb) — expand
- [app/views/help/decisions.md.erb](app/views/help/decisions.md.erb) — absorb `/learn/acceptance-voting`
- [app/views/help/commitments.md.erb](app/views/help/commitments.md.erb) — absorb `/learn/reciprocal-commitment`
- [app/views/help/api.md.erb](app/views/help/api.md.erb) — expand endpoint coverage, fix scopes
- [app/views/notes/_awareness_indicators_tooltip.html.erb](app/views/notes/_awareness_indicators_tooltip.html.erb) — update URL
- [app/views/decisions/_acceptance_voting_tooltip.html.erb](app/views/decisions/_acceptance_voting_tooltip.html.erb) — update URL
- [app/views/commitments/_reciprocal_commitment_tooltip.html.erb](app/views/commitments/_reciprocal_commitment_tooltip.html.erb) — update URL
- [test/integration/help_pages_test.rb](test/integration/help_pages_test.rb) — new topics + feature-flag gating tests

### 6. New Files to Create

- `app/views/help/automations.md.erb`
- `app/views/help/webhooks.md.erb` (or fold into automations)
- `app/views/help/notifications.md.erb`
- `app/views/help/billing.md.erb`
- `app/views/help/representation.md.erb`
- `app/views/help/settings.md.erb`

### 7. Files to Delete

- [app/controllers/learn_controller.rb](app/controllers/learn_controller.rb)
- [app/views/learn/](app/views/learn/) (entire directory)
- [test/controllers/learn_controller_test.rb](test/controllers/learn_controller_test.rb)

## Verification

1. Run help integration tests: `docker compose exec web bundle exec rails test test/integration/help_pages_test.rb`
2. Run learn controller test removal (verify file is gone): `docker compose exec web bundle exec rails test test/controllers/ 2>&1 | grep -i learn` (should produce no matches)
3. Run type checker: `docker compose exec web bundle exec srb tc`
4. Run rubocop: `docker compose exec web bundle exec rubocop`
5. Manual: visit `/help` in browser as a tenant with `stripe_billing` disabled — verify Billing topic is hidden; toggle on — verify it appears. Repeat for `api` and `ai_agents` flags.
6. Manual: visit `/help/billing` directly when `stripe_billing` is disabled — verify it 404s.
7. Manual: visit each `/learn/*` URL — verify they 404 (route is gone).
8. Manual: hover over awareness/voting/commitment tooltips — verify they now link into the help system, not `/learn`.
9. Test markdown format with `Accept: text/markdown` header on a sample of pages.
