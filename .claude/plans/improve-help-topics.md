# Plan: Improve In-App Help Topics

## Context

The in-app help system at `/help` currently has 10 topics. Several significant features have no help coverage at all, and the index page is a flat list with a brief quick-start section. As the app has grown, the help hasn't kept pace — users (both human and AI) have no in-app guidance for automations, webhooks, notifications, billing, representation, and more.

## Current State

**Existing topics (10):** privacy, collectives, notes, decisions, commitments, cycles, search, links, agents, api

**Controller:** `app/controllers/help_controller.rb` — defines `TOPICS` array, dynamically generates routes/actions  
**Content:** `app/views/help/{topic}.md.erb` — markdown with ERB  
**Routes:** `config/routes.rb:158-161` — `/help` index + `/help/{topic}` for each  
**Tests:** `test/integration/help_pages_test.rb`

## Gap Analysis

### Missing Topics (no help page exists)

| Feature | Coverage Gap | Key Source Files |
|---------|-------------|-----------------|
| **Automations** | Major feature with no help page. Comprehensive docs exist at `docs/AUTOMATIONS.md` but nothing in-app. Covers agent automations, collective automations, triggers, conditions, actions, YAML config. | `app/controllers/agent_automations_controller.rb`, `app/controllers/collective_automations_controller.rb` |
| **Webhooks** | Incoming webhooks (external systems triggering automations) have no help page. Related to automations but distinct enough for its own section or page. | `app/controllers/incoming_webhooks_controller.rb` |
| **Notifications** | No help page. Users can receive, dismiss, and manage notifications. Reminders can be created from notifications. | `app/controllers/notifications_controller.rb` |
| **Billing** | No help page. Subscriptions, per-identity pricing, credit topups, agent activation costs. | `app/controllers/billing_controller.rb` |
| **Representation & Trustees** | Collectives page briefly mentions representation, but trustee grants (delegating authority to act on your behalf) and representation sessions have no dedicated coverage. | `app/controllers/trustee_grants_controller.rb`, `app/controllers/representation_sessions_controller.rb` |
| **Comments** | Mentioned in one sentence on the notes page ("A comment is itself a note"), but no dedicated explanation of the commenting system, replies, or threading. | Part of notes/decisions/commitments |
| **Attachments** | No mention in help. Users can attach files to notes, decisions, commitments. | `Attachable` concern |
| **Pinning** | No mention in help. Content can be pinned for visibility within a collective. | `Pinnable` concern |
| **Heartbeats** | Mentioned in cycles page but could use more context — it's a distinctive feature that new users encounter immediately. | Part of cycles |
| **Content Reporting** | No mention. Users can report content for moderation. | Moderation controllers |
| **Two-Factor Authentication (2FA)** | No mention. Users can set up TOTP 2FA, manage backup codes. | 2FA controllers |
| **User Profiles & Settings** | No help page. Handles, avatars, personal settings. | `app/controllers/users_controller.rb` |

### Existing Topics with Minimal Coverage

| Topic | What's Missing |
|-------|---------------|
| **API** | Very brief (38 lines). Only shows 4 example endpoints. Missing: full endpoint list, scopes (now 4: read/create/update/delete not just read/write), error handling, rate limits, pagination, include params. |
| **Agents** | No mention of automations (the primary way agents act autonomously). No mention of agent billing. Task runs not explained. |
| **Collectives** | No mention of: invitations workflow, adding AI agents, enabling API access, collective automations, heartbeat requirement, collective identity user. |
| **Notes** | No mention of: subtypes (text, reminder, table), attachments, pinning, links/backlinks from notes, deadlines, content reporting. |

### Index Page Organization

Current index is a flat list of 10 items plus a 3-step quick start. With more topics, it needs categorical organization.

## Remove Stale Learn Pages

The `/learn` section is a separate set of conceptual explainer pages that predates the help system. These should be retired — their content merged into help pages where useful, and all references updated.

**Note:** `/motto` is its own route (`motto#index`, `config/routes.rb:195`) with its own controller — completely independent of the learn system. It is linked in the application layout footer and must NOT be touched. The learn index merely linked to it.

### Learn Pages Inventory

| Page | Content Summary | Merge Target |
|------|----------------|--------------|
| `/learn` (index) | Links to all learn pages + `/motto` | Remove entirely (help index replaces it) |
| `/learn/awareness-indicators` | Explains confirmed reads as awareness signals for group coordination | Merge into `help/notes` — expand the "Confirming Read" section with this conceptual framing |
| `/learn/acceptance-voting` | Explains acceptance voting as a negotiation-oriented method | Merge into `help/decisions` — the existing page already covers mechanics well; add the "why" from this page |
| `/learn/reciprocal-commitment` | Explains conditional commitment with critical mass (like Kickstarter for participation) | Merge into `help/commitments` — add the "why" framing to the existing page |
| `/learn/ai-agency` | Parent responsibility and visible accountability for AI agents | Merge into `help/agents` — add accountability/parent responsibility section |
| `/learn/superagency` | Collectives acting as unified agents through representation | Merge into `help/representation` (new page) or `help/collectives` |
| `/learn/memory` | Route exists but **no content file** — currently 404s | Remove entirely |

### References to Update

3 tooltip partials link to learn pages and need URL updates:
- `app/views/notes/_awareness_indicators_tooltip.html.erb` → change `/learn/awareness-indicators` to `/help/notes#confirming-read`
- `app/views/decisions/_acceptance_voting_tooltip.html.erb` → change `/learn/acceptance-voting` to `/help/decisions#how-acceptance-voting-works`
- `app/views/commitments/_reciprocal_commitment_tooltip.html.erb` → change `/learn/reciprocal-commitment` to `/help/commitments#how-critical-mass-works`

### Files to Remove
- `app/controllers/learn_controller.rb`
- `app/views/learn/` (entire directory — index.md.erb, show.html.erb, all .md and .md.erb files)
- `test/controllers/learn_controller_test.rb`
- Learn routes from `config/routes.rb:188-194`
- Any learn-related entries in `test/integration/markdown_ui_test.rb`

## Proposed Changes

### 1. New Help Topics to Add

**Priority 1 — Major missing features:**
- `automations` — Condensed version of docs/AUTOMATIONS.md for in-app consumption. Cover both agent and collective automations, trigger types, basic YAML examples. Link to full docs for schema reference.
- `notifications` — How notifications work, dismissing, reminders.
- `billing` — Pricing model, subscriptions, credits, what costs what.

**Priority 2 — Important supporting features:**
- `representation` — Trustee grants, representation sessions, collective agency in practice. (Currently a brief section in collectives — deserves its own page given its complexity.)
- `settings` — User profile, 2FA, API tokens, managing your account. (API tokens currently in the api page; 2FA and profile have no coverage.)

**Priority 3 — Smaller features to fold into existing pages rather than new pages:**
- Expand `notes` to cover subtypes, attachments, pinning, deadlines, content reporting
- Expand `agents` to mention automations (with link), task runs, billing
- Expand `collectives` to mention invitations, adding agents, enabling API, collective automations
- Expand `api` with more endpoints, correct scopes, pagination

### 2. Reorganize the Index

Group topics into categories:

```
## Getting Started
- Privacy — Public, shared, and private spaces
- Collectives — Groups with shared spaces and external identities
- Settings — Your profile, security, and preferences

## Content
- Notes — Posts, updates, and reflections
- Decisions — Group choices via acceptance voting
- Commitments — Conditional action pledges with critical mass
- Cycles — Repeating time windows and heartbeats
- Search — Finding content across collectives
- Links — Bidirectional references between content

## Automation & Integration
- Agents — AI agents that navigate and act in Harmonic
- Automations — Event-driven and scheduled workflows
- API — Programmatic access via tokens and REST
- Notifications — Alerts, reminders, and updates

## Account
- Billing — Subscriptions, credits, and pricing
- Representation — Trustee grants and acting on behalf of others
```

### 3. Implementation Steps

For each new/expanded topic:

1. Add topic name to `TOPICS` array in `app/controllers/help_controller.rb`
2. Add route in `config/routes.rb` (already dynamic from TOPICS array — just needs the controller constant updated)
3. Create `app/views/help/{topic}.md.erb` with content
4. Update `app/views/help/index.md.erb` with new organization
5. Update `test/integration/help_pages_test.rb` to cover new topics

### 4. Files to Modify

- `app/controllers/help_controller.rb` — add new topic names to TOPICS
- `config/routes.rb:158-161` — update the topic list (mirrors TOPICS)
- `app/views/help/index.md.erb` — reorganize with categories
- `app/views/help/notes.md.erb` — expand coverage
- `app/views/help/agents.md.erb` — expand coverage  
- `app/views/help/collectives.md.erb` — expand coverage
- `app/views/help/api.md.erb` — expand coverage

### 5. New Files to Create

- `app/views/help/automations.md.erb`
- `app/views/help/notifications.md.erb`
- `app/views/help/billing.md.erb`
- `app/views/help/representation.md.erb`
- `app/views/help/settings.md.erb`

## Verification

1. Run help integration tests: `docker compose exec web bundle exec rails test test/integration/help_pages_test.rb`
2. Run type checker: `docker compose exec web bundle exec srb tc`
3. Visit `/help` in browser to verify index organization
4. Visit each new topic page to verify rendering
5. Test markdown format with `Accept: text/markdown` header
