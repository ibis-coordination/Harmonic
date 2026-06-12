# Docs Refresh + Phantom Event Types

## Sequencing

The [notifications read state work](notifications-read-state.md) this plan was sequenced behind **landed in PR #228 (merged 2026-06-11)** — all phases here are unblocked. That merge also raised the stakes for Phase 2: the rewritten `/help/notifications` now documents a **Participation** notification type triggered by votes, commitment joins, decision resolution, and critical mass — exactly the four notification paths the phantom-event bug prevents from ever firing. The help doc is no longer merely incomplete; it promises behavior that doesn't happen until Phase 2 ships. (Once Phase 2 lands, the help text becomes accurate as written — verify against it, no further edit expected.)

## Context

A June 2026 review of all developer docs (`docs/`) and in-app help topics (`app/views/help/`) found most documents fresh. The actionable findings fall into three buckets:

1. **A family of phantom event types** — `NotificationDispatcher` has handlers for five event types that nothing ever emits, and the in-app automation reference advertises event types that never fire. This is a code bug, not a doc bug.
2. **`docs/AUTOMATIONS.md` needs a major rewrite** — last touched 2026-02-27, it predates the commitment subtypes, the per-recipient webhook redesign, and roughly 17 automation-related commits. Its rewrite depends on bucket 1, since the event vocabulary it documents must be the fixed one.
3. **A sweep of small, mechanical doc fixes** — independent of everything else.

### The phantom event family (verified)

The real event vocabulary today:

- `Tracked` concern ([app/models/concerns/tracked.rb](../../app/models/concerns/tracked.rb)) emits `<model_underscore>.created|updated|deleted` for: `Note`, `Decision`, `Commitment`, `Option`, `Vote`, `ChatMessage`, `UserListMember`
- [app/jobs/deadline_event_job.rb:90](../../app/jobs/deadline_event_job.rb#L90) emits `decision.deadline_reached`, `commitment.deadline_reached`
- `notifications.delivered` / `reminders.delivered` from the delivery jobs

Five event types are handled in [notification_dispatcher.rb:8-31](../../app/services/notification_dispatcher.rb#L8-L31) but **never emitted anywhere**:

| Phantom type | Dead handler does | Why it never fires | User-visible consequence |
|---|---|---|---|
| `commitment.joined` | Notify commitment creator of a join | `CommitmentParticipant` is not `Tracked`; the join flow ([api_helper.rb:248](../../app/services/api_helper.rb#L248), `CommitmentParticipantManager`) emits nothing | "X joined your commitment" notifications never happen |
| `commitment.critical_mass` | Notify all participants | No emission site exists | Notifications never happen; the "Commitment Milestone Tracker" automation template ([automation_template_gallery.rb:142](../../app/services/automation_template_gallery.rb#L142)) silently never triggers |
| `decision.voted` | Notify decision creator | Votes emit `vote.created` with subject `Vote`; the handler expects subject `Decision` | "Someone voted on your decision" notifications never happen |
| `decision.resolved` | Notify participants | Nothing emits it; deadline resolution emits `decision.deadline_reached`, which `NotificationDispatcher` doesn't handle at all | "A decision you participated in resolved" notifications never happen |
| `comment.created` | Notify content owner | Comments are `Note` rows (subtype `comment`), so they emit `note.created` | Notifications still work — `handle_note_event` calls `handle_reply_notification`, which duplicates the dead handler. But automations on `comment.created` never fire |

Additionally, the in-app automation YAML reference ([\_automation\_yaml\_reference.md.erb:63-71](../../app/views/shared/_automation_yaml_reference.md.erb#L63-L71) and the `.html.erb` twin) advertises `comment.created`, `reply.created`, and `commitment.critical_mass` to automation authors. Rules built on any of these match nothing — `AutomationDispatcher.find_matching_rules` filters on raw `event_type` with no aliasing.

## Phase 1 — Minor docs sweep

One PR, no behavior changes. All verified against the codebase 2026-06-11:

1. **CLAUDE.md:54** — "Rails 7.2" → "Rails 8.1" (Gemfile: `gem "rails", "~> 8.1"` since the rails-8-upgrade merge). Ruby 3.3.7 is still correct.
2. **docs/ARCHITECTURE.md** — add missing concerns to the model-concerns table (`SoftDeletable`, `Searchable`, `InvalidatesSearchIndex`, `TracksUserItemStatus`, `HasRepresentationSessionEvents`, `Statementable`); add a section for the `UserList` / lists feature (routes at `/lists`, tune-in, custom lists, list notifications) — entirely absent today.
3. **docs/USER_TYPES.md:77** — diagram label "SUBAGENT USER" → "AI AGENT USER"; the term "subagent" appears nowhere in the codebase (`user_type` enum is `ai_agent`).
4. **docs/STYLE_GUIDE.md:18** — monospace stack is documented as `"Source Code Pro", "Lucida Console", monospace`, but Pulse CSS uses `ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace`. Update the doc; also fix the undefined `--fontStack-monospace` variable referenced in `pulse/_layout.css` (either define it in `root_variables.css` or replace with the literal stack). Mark the typography size/weight table as recommended defaults, since `pulse/_base.css` doesn't enforce them.
5. **docs/API.md** — link to `.claude/plans/v1-api-readonly.md` is broken; the plan moved to `.claude/plans/completed/2026/05/`. Prefer dropping the plan link entirely and pointing at `/help/rest-api`.
6. **docs/DEPLOYMENT.md** — note Rails 8.1 in the environment section; introduce `RegenerateCaddyfileJob` before first prose use.
7. **app/views/help/lists.md.erb:3** — "primary list" is internal-only vocabulary; rephrase using "tune in" language (e.g. "a list of everyone you've tuned in to, plus optional custom lists").
8. **app/views/help/notes.md.erb** and **reminder_notes.md.erb** — both describe a "subtype toggle"; the UI is three buttons (Post, Reminder, Table). notes.md.erb also omits Reminder from the list.

CHANGELOG.md is updated post-merge, not in the PR.

## Phase 2 — Fix the phantom event types

Red-green TDD throughout: each fix starts with a failing `notification_dispatcher_test.rb` / model / service test proving the event fires and the notification is created.

### 2a. `commitment.joined` — add emission

Emit when a participant's `committed_at` transitions nil → set (an `after_save_commit` on `CommitmentParticipant`, or explicitly in the join flow — decide during implementation; the model callback covers both the HTML and md-action paths, which converge on `CommitmentParticipantManager` + `committed = true`). Subject: the `Commitment` (the existing handler expects it); actor: the joining user. Skip during `Current.importing_data`, matching `Tracked`.

### 2b. `commitment.critical_mass` — add emission (the originally reported bug)

Fire once, when a join causes `participant_count` to cross from below `critical_mass` to at-or-above it (check crossing, not state, so it doesn't re-fire on every subsequent join). Emit alongside 2a in the same code path. Subject: the `Commitment`; actor: the user whose join crossed the threshold.

Edge cases to test:
- Lowering `critical_mass` in settings to at-or-below the current count does **not** fire the event (settings changes aren't joins; lowering below current count is already blocked when participants exist, per [commitments_controller.rb:260](../../app/controllers/commitments_controller.rb#L260)).
- `close_at_critical_mass?` commitments: event fires before/regardless of auto-close.
- A leave-then-rejoin that re-crosses the threshold: decide whether it re-fires (recommend yes — it's a genuine crossing; the automation rate limits and notification layer absorb repeats).

This makes the dead notification handler and the "Commitment Milestone Tracker" gallery template live for the first time — verify the template's `mention_filter: self` semantics still make sense with a real event, and exercise it in an automation test.

### 2c. `decision.voted` — route from the real event

Don't add a second event per vote. Route `vote.created` in `NotificationDispatcher` to the vote handler, deriving the `Decision` from the `Vote` subject; delete the dead `decision.voted` case.

**Volume guard required:** a participant voting across N options creates N `Vote` rows → N notifications to the decision owner. Add dedup before enabling: suppress while an unread notification from the same (decision, voter) exists — the same unread-keyed pattern now shipped in `NotificationService.notify_chat_message!` and `NotificationDispatcher.recent_tune_in_notification_exists?` (PR #228).

### 2d. `decision.resolved` — route from the real event

`NotificationDispatcher` doesn't handle `decision.deadline_reached` at all today. Route it to the resolved handler (renaming as appropriate); delete the dead `decision.resolved` case. During implementation, confirm deadline passage is the only resolution path for decisions — if a no-deadline resolution path exists, cover it too.

### 2e. `comment.created` — decision required

Comment **notifications** already work via `note.created` → `handle_reply_notification`. The dead `handle_comment_event` duplicates that logic — delete it regardless. The open question is the **automation contract**, since the in-app reference advertises `comment.created` and `reply.created`:

- **Option A (recommended): make `comment.created` real.** Override the `Tracked` event type in `Note` to emit `comment.created|updated|deleted` when `is_comment?`, and route `comment.*` through the same dispatcher path as `note.*` (mentions in comments must keep notifying). Honors the advertised contract; makes `note.created` mean top-level notes only.
  - Breaking-change check: audit existing `AutomationRule` rows for `note.created` triggers that depend on firing for comments. If any plausibly do, announce/migrate accordingly.
- **Option B: correct the docs.** Remove `comment.created`/`reply.created` from the YAML reference and gallery, document filtering `note.created` by subtype via rule conditions (verify conditions support this first).
- Either way, drop `reply.created` from the advertised list — a reply is a comment; three tiers of the same thing is vocabulary sprawl. (Under Option A it would fire as `comment.created` anyway.)

### 2f. Align the advertised event list

Update [\_automation\_yaml\_reference.md.erb](../../app/views/shared/_automation_yaml_reference.md.erb) and its `.html.erb` twin so the Event Types list exactly matches what fires after 2a-2e: the `Tracked` vocabulary actually useful to authors, both `deadline_reached` types, `commitment.joined`, `commitment.critical_mass`, and (per the 2e decision) `comment.created`. This ships in the same PR as the behavior changes — the reference is the user-facing contract for them.

## Phase 3 — Rewrite docs/AUTOMATIONS.md

Depends on Phase 2 (documents the corrected event vocabulary). Full-pass rewrite against the current system:

1. **Event types**: complete list including `decision.deadline_reached`, `commitment.deadline_reached`, `chat_message.*`, `option.*`, `vote.*`, `user_list_member.*`, the newly real `commitment.joined` / `commitment.critical_mass`, and the special-cased `notifications.delivered` / `reminders.delivered` (which bypass mention filters and key the self-trigger guard on the recipient — see `AutomationDispatcher::NOTIFICATION_DELIVERED_EVENTS`).
2. **Webhooks**: rewrite the webhook trigger section for the per-recipient design (one notification webhook per user/agent forwarding all notifications, commit `ed688c14`, 2026-06-07), replacing the per-trigger webhook description.
3. **Commitment subtypes**: update examples and `internal_action` parameter docs for `action` / `calendar_event` / `policy` subtypes (commit `c772a9cd`).
4. **Billing gate**: document that automations are a paid feature and events on non-paid collectives match no rules (with the notification-webhook bypass), per `AutomationDispatcher.find_matching_rules`.
5. **Clarify `trigger_agent`** invokes other agents, not the rule's owner.
6. Verify the internal-action attribution-badge claims still hold after the representation-session changes.

Cross-check the rewrite against `app/views/help/automations.md.erb` (currently fresh) so the two stay consistent; update the help topic only if Phase 2 changed user-visible behavior it describes.

## Decision points

| # | Decision | Recommendation |
|---|---|---|
| 1 | Emission site for join/critical-mass events: model callback vs. join service | Model-level `after_save_commit` on `committed_at` transition (covers all entry points) |
| 2 | Re-fire `commitment.critical_mass` on leave/rejoin re-crossing | Yes — it's a real crossing; dedup belongs downstream |
| 3 | `comment.created`: implement (Option A) vs. document reality (Option B) | Option A, pending the `note.created` automation-rule audit |
| 4 | Vote-notification dedup keying | Unread-keyed per (decision, voter), matching the shipped suppression semantics for chat and tune-in |

## Out of scope

- `/help/notifications` content — fully rewritten in PR #228; it now documents all notification types and the read/dismiss model. No edits needed here beyond Phase 2 verifying its participation claims become true.
- Docs verified fresh and needing nothing: AGENT_RUNNER.md, REPRESENTATION.md, BILLING.md, MONITORING.md, SAFETY.md, SECURITY_AND_SCALING.md, guides/MARKDOWN_UI_SERVICE_USAGE.md, and 20 of 23 help topics.
- Notification aggregation, real-time badge, `/api/v1` notification endpoints — tracked in the read-state plan's "Other improvements" (retention/purge shipped in PR #228).
