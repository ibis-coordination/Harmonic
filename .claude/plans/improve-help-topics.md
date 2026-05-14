# Plan: Improve In-App Help Topics

## Context

The in-app help system at `/help` had grown to 14 topics but several major features had no coverage (automations, notifications, REST API, representation), the index was a flat list mixing concepts and features, and a parallel `/learn` system with mostly-redundant content sat alongside it. The first round of work has landed; this doc tracks what's done and what's still open.

## Status

### Done — shipped on branch `improve-help-topics`

Each is a separate commit on the branch (most recent first):

1. **Add REST API help topic, make /api/v1 info endpoint dynamic** ([app/views/help/rest_api.md.erb](app/views/help/rest_api.md.erb), [app/controllers/api/v1/info_controller.rb](app/controllers/api/v1/info_controller.rb), [test/integration/api_info_test.rb](test/integration/api_info_test.rb))
2. **Harden API token model: immutability, cap, scope downscoping, safer responses** ([app/controllers/api/v1/api_tokens_controller.rb](app/controllers/api/v1/api_tokens_controller.rb), [app/models/api_token.rb](app/models/api_token.rb)) — security work that surfaced while writing the REST API docs; see PR description for full list
3. **Split markdown UI out of the API help topic** ([app/views/help/markdown_ui.md.erb](app/views/help/markdown_ui.md.erb))
4. **Add representation help topic and regroup the index** ([app/views/help/representation.md.erb](app/views/help/representation.md.erb))
5. **Add notifications help topic** ([app/views/help/notifications.md.erb](app/views/help/notifications.md.erb))
6. **Add automations help topic** ([app/views/help/automations.md.erb](app/views/help/automations.md.erb))
7. **Reorganize help index into categories** (How Harmonic Works / Content / Finding & Following / Agency & Integration)
8. **Retire /learn pages, fold content into /help** — content merged into notes (awareness indicators), decisions (acceptance voting framing), commitments (reciprocal commitment framing), agents (accountability section); 3 tooltip partials updated; entire `/learn` directory + controller + tests removed
9. **Gate api and agents help topics behind feature flags** — `FEATURE_GATED_TOPICS` constant; topic returns 404 and disappears from index when flag is off

### Current topic surface

| Section | Topics |
|---------|--------|
| **How Harmonic Works** | Privacy, Collectives, Cycles |
| **Content** | Notes (+ Reminder, Table), Decisions (+ Executive, Lottery), Commitments |
| **Finding & Following** | Search, Links, Notifications |
| **Agency & Integration** | Representation, Agents *(gated)*, Automations, API *(gated)*, Markdown UI, REST API *(gated)* |

### Topic ↔ Feature Flag mapping (live)

| Topic | Flag | Behavior when off |
|-------|------|-------------------|
| `api` | `api` | Topic 404s; link hidden from index |
| `rest_api` | `api` | Same |
| `agents` | `ai_agents` | Same |
| All others | (none) | Always visible |

## Remaining work

### Topics still missing

| Topic | Feature flag | Notes |
|-------|--------------|-------|
| **Billing** | `stripe_billing` | Pricing model, subscriptions, credits, identity-based pricing. Gated. |
| **Settings** | none | User profile, 2FA, account management. (API tokens are already covered in `/help/api`.) |
| **Webhooks** | none | Brief mention exists in `/help/automations`; may deserve its own page or stay as a section there. |

### Existing topics with thin coverage

| Topic | What's missing |
|-------|---------------|
| **Agents** | Mention of agent automations (now exists; link), task runs, agent billing/usage |
| **Collectives** | Invitations workflow, adding AI agents, enabling API access, collective automations, heartbeat requirement |
| **Notes** | Attachments (`file_attachments`-gated section), pinning, links/backlinks from notes, deadlines, content reporting |

### Possible additions (not yet decided)

- Comments — currently a sentence in notes; could expand to cover threading, where comments can be posted
- Pinning — small concept used across notes/decisions/commitments
- Content reporting / moderation
- Attachments as a standalone section under notes (feature-gated)

## Out of scope but related

- **v1 REST API read-only proposal** — see [.claude/plans/v1-api-readonly.md](.claude/plans/v1-api-readonly.md). The token-hardening work surfaced concerns about the v1 API's drift and the parallel write paths between REST and action routes. Pulling that forward as its own branch.

## Implementation pattern (for the remaining topics)

Each new topic follows the same recipe:

1. Add to `TOPICS` in [app/controllers/help_controller.rb](app/controllers/help_controller.rb)
2. Add to the route list in [config/routes.rb](config/routes.rb)
3. Add to `FEATURE_GATED_TOPICS` if applicable
4. Create `app/views/help/{topic}.md.erb` — verify every factual claim against source code before showing
5. Add a link in [app/views/help/index.md.erb](app/views/help/index.md.erb) (gated if applicable)
6. Add to `TOPICS` (and `GATED_TOPICS` if applicable) in [test/integration/help_pages_test.rb](test/integration/help_pages_test.rb) — the parameterized test sweep handles the rest

## Lessons from the first round

- **Verify every claim against source.** I made several confident-sounding errors in early drafts (claimed system notifications get sent, claimed participation notifications exist when the dispatcher's trigger events are never emitted in production, claimed update could change scopes/expiration). Each one got caught only when the user pushed back. Better to read the source first and write second.
- **Mind the audience.** AI agents also read these docs; second-person framing addressed at humans is misleading when the topic applies to anyone with a token. Third-person is safer.
- **Help-doc work tends to surface real bugs.** The drift in InfoController, the participation-notification gap, the v1 scope-update escalation, the token-extension vulnerability — all came up while trying to write accurate help text. Worth budgeting for that.
