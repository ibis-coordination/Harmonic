# Summaries as Notes

## Goal

Each summarizable resource (Note, Decision, Commitment) can have at most one **summary**, written as a Note with `subtype: "summary"` linked back through a polymorphic `summarizable` association. Writing summaries is gated to collective members with the new **summarizer** role. The summary lives at a canonical `<parent>/summary` URL so agents can fetch it in one request without first learning the summary note's id.

## What shipped

### Data model

- `Summarizable` concern (`app/models/concerns/summarizable.rb`) included in `Note`, `Decision`, `Commitment`. Provides `has_one :summary` (scoped to `subtype: "summary"`, `dependent: :destroy`), `can_write_summary?(user)`, and `is_summarizable?`.
- `Note::SUBTYPES` extended with `"summary"`. Note adds `belongs_to :summarizable, polymorphic: true`, the `summaries_must_be_summary_subtype` validation, and `is_summary?` / `has_summarizable?` predicates.
- `Note#is_summarizable?` overridden to `!is_summary?` so a summary cannot itself be summarized.
- `Note#path` overridden to return `<summarizable.path>/summary` for summary notes (with a nil-safe fallback for orphaned summaries).
- Migration adds polymorphic `summarizable_type` (string) + `summarizable_id` (UUID) on notes with a UNIQUE index — DB-level enforcement of the one-summary-per-resource invariant.

### Authorization

- New `'summarizer'` role added to `HasRoles.valid_roles`. `CollectiveMember#can_summarize?` mirrors `can_represent?` (role check + collective-level `any_member_can_summarize?` override + archived guard).
- `Summarizable#can_write_summary?(user)` resolves the user's CollectiveMember in the resource's collective and delegates to `can_summarize?`.
- Collective settings UI gains a "Summarization" radio matching the existing Representation pattern; `any_member_can_summarize` defaults to false and is locked off for private workspaces and chat collectives.
- Team UI gains a `summarizer` badge alongside the existing `representative` and `admin` badges. No per-member grant UI in this PR — granting is via rails console (parity with the representative role).

### Action surface

- `add_summary` action defined in `ActionsHelper::ACTION_DEFINITIONS` ("Add or update the summary of this item.") with `authorization: :collective_member`.
- Routes `GET/POST /actions/add_summary` on each of `/n/:id`, `/d/:id`, `/c/:id`.
- Generic `describe_add_summary` + `add_summary` actions live on `ApplicationController` (mirroring the `add_comment` pattern). The POST gates on `is_summarizable?` then `can_write_summary?` before delegating to `api_helper.add_summary`.
- `api_helper.add_summary(summarizable:)` upserts via `create_or_update_summary!` (mirrors `create_or_update_statement!`). Records a representation-session event when applicable.
- Markdown action discovery: `add_summary` lives in `conditional_actions:` on all three resource paths, guarded by `ADD_SUMMARY_CONDITION` which checks both `is_summarizable?` and `can_write_summary?(user)`. Agents only see the action listed when they can actually use it.

### Canonical summary URL

- `/n/:id/summary`, `/d/:id/summary`, `/c/:id/summary` routes serve summaries at the parent's address. Each resource controller has a thin `summary` action that calls `ApplicationController#render_summary_for(parent)`.
- `render_summary_for`:
  - 404 if the parent is missing or not `is_summarizable?` (catches summary-of-summary URLs).
  - 200 with `shared/no_summary` (HTML + MD) when the parent exists but has no summary. The page tells summarizer-role viewers how to write one and tells everyone else to ask a summarizer.
  - 200 with `shared/summary` (HTML + MD) when a summary exists.
- `set_pin_vars` refactored to accept a `resource:` kwarg so the summary path computes real pin state for the summary note (rather than hardcoding false).
- The legacy `/n/<summary_truncated_id>` route still resolves through `notes#show` for any existing links / bookmarks.

### View layer

- `notes/show.html.erb` and `notes/show.md.erb` slimmed down to a wrapping span + breadcrumb + a render of the new shared `_note_main` partial. The article body lives in `app/views/shared/_note_main.{html,md}.erb`, takes a `note:` parameter, and is reused by `shared/summary.{html,md}.erb`.
- `shared/summary.{html,md}.erb` live in the shared namespace so they're free to diverge from `notes/show` without coupling.
- All relative partial renders in notes views (`render 'confirm'`, `render 'history'`, `render 'history_log'`, `render 'table'`) converted to absolute paths so the shared partials render cleanly from any controller.

### Summary section (parent pages)

- `shared/_summaries_section.{html,md}.erb` renders on the parent resource's show page.
- HTML: hidden by default. Revealed by kebab-menu items: **View summary** (when a summary exists) and **Add summary / Edit summary** (when the viewer can write one). A new `SummaryToggleController` Stimulus controller drives the reveal. The section sits directly below the kebab menu, above the resource body.
- Markdown: renders `## Summary` + a single-line link to the summary's show page. The summary's full text is only at `<parent>/summary`, never inlined on the parent page.

### Feed items

- `FeedItemComponent` gains `is_statement?` / `is_summary?` predicates. Both subtypes render with their own type icon (`law` / `book`), a `pulse-feed-item-reply` block linking to the parent ("Statement on …" / "Summary of …"), and the title row suppressed (parallel to how comments already render).

### Search

- `subtype:summary` and `subtype:statement` were already accepted by the parser (both live in `Note::SUBTYPES`). The help, search-page markdown, and search-page HTML docs now list them in the value enumeration. A pre-existing `text` → `post` typo on the HTML doc fixed alongside.

### Tests

- ~40 tests across `test/models/concerns/summarizable_test.rb`, `test/models/collective_member_test.rb`, `test/models/note_test.rb`, `test/services/search_query_test.rb`, `test/components/feed_item_component_test.rb`, and `test/controllers/add_summary_action_test.rb` cover model invariants, role gating, action upsert, conditional action discovery, view rendering (HTML + MD), feed item rendering, summary path 200/404 cases including the no-summary fallback, anonymous viewer access, and the legacy `/n/<summary_id>` route.

## Out of scope / future work

In rough order of when they make sense to revisit:

1. **Specialized summarizer AI persona.** A built-in agent (working name "Rolly") with a focused system prompt and scripted affordances for summarization. Hangs off the summarizer role.
2. **Per-member role grant UI.** Currently rails-console-only for both summarizer and representative roles. Worth doing for both at once.
3. **Cycle summaries.** Summarize activity over a time-bounded window.
4. **Collective-member summaries.** Summaries scoped to a person's activity.
5. **Scheduled / rolled-up / hierarchical summaries.** Day → week → month → quarter → year rollups so agents can drill from coarse to fine without loading the full thread.
