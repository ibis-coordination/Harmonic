# Anonymous read access — Phase 0 audit notes

Read-only audit of code paths reachable from the four anon entry points. Drives Phases 1–4 of [anonymous-read-access-main-collective.md](anonymous-read-access-main-collective.md).

Entry points:
- `GET /n/:note_id` → [NotesController#show](app/controllers/notes_controller.rb#L6)
- `GET /d/:decision_id` → [DecisionsController#show](app/controllers/decisions_controller.rb#L76)
- `GET /c/:commitment_id` → [CommitmentsController#show](app/controllers/commitments_controller.rb#L6)
- `GET /help` and `GET /help/:topic` → [HelpController](app/controllers/help_controller.rb) (`#index` + dynamic per-topic methods defined at [help_controller.rb:31-45](app/controllers/help_controller.rb#L31-L45))

## Headline findings

1. **Insertion point holds.** The 6-condition bypass in [plan §B](anonymous-read-access-main-collective.md#L46) belongs in [validate_unauthenticated_access at app/controllers/application_controller.rb:562-579](app/controllers/application_controller.rb#L562-L579), after the two existing `return if` lines (563–564) and before the `/login` redirect (line 578).
2. **`validate_unauthenticated_access` is not a `before_action`** — it's invoked transitively through [`current_user` (line 191) → `resolve_browser_session_user` (line 376) → `validate_access` (line 469) → `validate_unauthenticated_access`](app/controllers/application_controller.rb#L191). Because `current_user` runs *after* `current_collective` in the [before_action chain (line 10-11)](app/controllers/application_controller.rb#L10-L11), `@current_tenant` and `@current_collective` are already set when the gate fires. Bypass conditions 2 and 3 (`public_main_collective?`, `is_main_collective?`) can read them safely.
3. **No unguarded `current_user` in any reached HTML partial.** Every reference goes through `@current_user && …`, `&.`, `if @current_user`, or method calls (`user_can_edit?(@current_user)`, `can_close?(@current_user)`) that already accept nil.
4. **No unguarded DB writes on GET.** The two write-on-read sites (`current_decision_participant`, `current_commitment_participant`) both branch on `current_user &&`.
5. **All app-chrome and auth before_actions early-return on nil user.** No Phase 1 work needed outside the bypass + the macro.
6. **Help is already minimal-chrome and user-free.** `@sidebar_mode = "minimal"` at [help_controller.rb:24](app/controllers/help_controller.rb#L24); zero `current_user` references in any `app/views/help/**`.

## Inventory 1 — HTML partial tree (per show + help)

### `/n/:note_id` HTML

**Entry:** [app/views/notes/show.html.erb](app/views/notes/show.html.erb)

| Partial / Component | File:line | Reference | Guarded? |
|---|---|---|---|
| `show.html.erb` | [40](app/views/notes/show.html.erb#L40) | `@note.user_can_edit?(@current_user)` | Method accepts nil → false |
| `show.html.erb` | [53](app/views/notes/show.html.erb#L53) | `show_pin = @current_user && !@current_collective.is_main_collective?` | `@current_user &&` |
| `show.html.erb` | [54](app/views/notes/show.html.erb#L54) | `show_report = @current_user && …` | `@current_user &&` |
| `_confirm.html.erb` | [1](app/views/notes/_confirm.html.erb#L1) | `@current_user && UserBlock.between?(…)` | `@current_user &&` |
| `_confirm.html.erb` | 20–125 | several `<% elsif @current_user %>` blocks with anon-CTA `<% else %>` branch | All guarded; **anon path already exists** (login CTA at line 107–125) |
| `shared/_pulse_comments.html.erb` | [13](app/views/shared/_pulse_comments.html.erb#L13) | `@current_user && commentable.respond_to?(:created_by_id) && …` | `@current_user &&` |
| `shared/_pulse_comments.html.erb` | [16](app/views/shared/_pulse_comments.html.erb#L16) | `@current_user.blocked?(commentable.created_by)` | Inside outer `@current_user &&` |
| `shared/_pulse_comments.html.erb` | [22](app/views/shared/_pulse_comments.html.erb#L22) | `<% elsif @current_user %>` — comment form | Guarded; anon `<% else %>` branch renders no form |
| `shared/_pulse_author.html.erb` | — | Delegates to `AuthorComponent` | No inline user refs |
| `shared/_pulse_attachments.html.erb` | — | Renders attachment download links only | No user refs |
| `shared/_pulse_backlinks.html.erb` | — | Iterates `@blocked_user_ids` (already nil-safe — see helper below) | Safe |

**Interaction surfaces** (Phase 3 will swap to `shared/_login_to_act.html.erb` where missing):
- Edit button — already `@current_user`-guarded
- Pin button — `show_pin` guard
- Report kebab — `show_report` guard
- Confirm-read / acknowledge-reminder — `_confirm.html.erb` already has explicit anon login CTA
- Comments form — `_pulse_comments.html.erb` already drops the form for anon (line 22 elsif)

**Layout:** [app/views/layouts/application.html.erb](app/views/layouts/application.html.erb)
- Top-right menu at [_top_right_menu.html.erb:2](app/views/layouts/_top_right_menu.html.erb#L2): `<% if @current_user %>` wraps notifications/search/profile/settings; `<% else %>` branch at line 103 renders Log in button. **Already anon-aware.**
- `SidebarComponent` with `@sidebar_mode = "resource"`: minimal user dependency in resource sidebar; spot-check during Phase 3.

### `/d/:decision_id` HTML

**Entry:** [app/views/decisions/show.html.erb](app/views/decisions/show.html.erb)

| Partial / Component | File:line | Reference | Guarded? |
|---|---|---|---|
| `show.html.erb` | [24](app/views/decisions/show.html.erb#L24) | `@decision.can_close?(@current_user)` | Method accepts nil |
| `show.html.erb` | [55](app/views/decisions/show.html.erb#L55) | `@decision.can_edit_settings?(@current_user)` | Method accepts nil |
| `show.html.erb` | [56](app/views/decisions/show.html.erb#L56) | `show_pin = @current_user` | Direct guard |
| `show.html.erb` | [57](app/views/decisions/show.html.erb#L57) | `show_report = @current_user && …` | `@current_user &&` |
| `show.html.erb` | [200](app/views/decisions/show.html.erb#L200) | `@current_user && UserBlock.between?(…)` | `@current_user &&` |
| `_options_section.html.erb` | [2](app/views/decisions/_options_section.html.erb#L2) | `!@participant.authenticated?` | `@participant` is nil for anon → method must not crash on nil receiver. **Verify in Phase 1 test** (see Risk A) |
| `_options_section.html.erb` | 3–5 | `<% else %>` renders login CTA "Log in to participate" | Anon path already present |
| `_options_section.html.erb` | [7](app/views/decisions/_options_section.html.erb#L7) | `@decision.can_close?(@current_user)` | Safe |
| `_options_section.html.erb` | [68](app/views/decisions/_options_section.html.erb#L68) | `can_add_options?(@participant)` (nil participant) | Verify method accepts nil |
| `_options_list_items.html.erb` | [15](app/views/decisions/_options_list_items.html.erb#L15) | `@votes.where(option: option).first` | `@votes` is nil for anon — surrounding template already routes anon through a read-only branch |
| `_results.html.erb` | — | No user refs | Safe |
| `shared/_pulse_comments.html.erb` | (same as notes) | | Same |
| `shared/_pulse_backlinks.html.erb` | (same as notes) | | Same |
| `StatementEmbedComponent` | [app/components/statement_embed_component.rb](app/components/statement_embed_component.rb) | Receives `current_user` | Verify in Phase 3 — component should accept nil |

**Interaction surfaces:** voting checkboxes, accept/prefer UI, add-option form, close-decision modal — all already gated on `@participant.authenticated?` or `@current_user`.

### `/c/:commitment_id` HTML

**Entry:** [app/views/commitments/show.html.erb](app/views/commitments/show.html.erb)

| Partial / Component | File:line | Reference | Guarded? |
|---|---|---|---|
| `show.html.erb` | [38](app/views/commitments/show.html.erb#L38) | `@commitment.can_edit_settings?(@current_user)` | Method accepts nil |
| `show.html.erb` | [44](app/views/commitments/show.html.erb#L44) | `show_pin = @current_user` | Direct guard |
| `show.html.erb` | [45](app/views/commitments/show.html.erb#L45) | `show_report = @current_user && …` | `@current_user &&` |
| `_status.html.erb` | — | No user refs | Safe |
| `_join.html.erb` | [25](app/views/commitments/_join.html.erb#L25) | `@commitment.closed? && @current_user` | `@current_user &&` |
| `_join.html.erb` | [39](app/views/commitments/_join.html.erb#L39) | `<% elsif @current_user %>` — join button | Guarded; anon `<% else %>` at line 76–79 renders "Log in to join this commitment" CTA |
| `_participants.html.erb` | — | No user refs | Safe |
| `_participants_list_items.html.erb` | — | No user refs | Safe |
| `shared/_pulse_comments.html.erb` | (same as notes) | | Same |
| `shared/_pulse_backlinks.html.erb` | (same as notes) | | Same |

**Interaction surfaces:** join/sign/RSVP — already has anon login CTA; pin, report, comments — already guarded.

### `/help[/:topic]` HTML

**Wrapper:** [app/views/help/show.html.erb](app/views/help/show.html.erb) renders `@help_html.html_safe` from markdown.

```
$ grep -rn "current_user\|@current_user\|user_signed_in\|session\[" app/views/help/
# (no output — zero user references)
```

Layout uses `@sidebar_mode = "minimal"` → [app/views/pulse/_sidebar_minimal.html.erb](app/views/pulse/_sidebar_minimal.html.erb) renders only a Home link.

Feature-gated topics (`api`, `rest_api`, `agents`, `trio`) 404 via [help_controller.rb:32-37](app/controllers/help_controller.rb#L32-L37) calling `help_topic_available?` which checks `current_tenant.feature_enabled?(flag)` — no user dependency.

## Inventory 2 — Markdown template tree

### `/n/:note_id.md`

**Entry:** [app/views/notes/show.md.erb](app/views/notes/show.md.erb)

| Reference | File:line | Risk |
|---|---|---|
| `resource_author_md(@note)` | [11](app/views/notes/show.md.erb#L11) | Helper at [application_helper.rb:160-173](app/helpers/application_helper.rb#L160-L173) returns "Anonymous" on nil author — safe |
| `render 'shared/automation_attribution'` | [23](app/views/notes/show.md.erb#L23) | No user refs |
| `user_link_md(event.user)` | [43](app/views/notes/show.md.erb#L43) | Helper at [application_helper.rb:146-155](app/helpers/application_helper.rb#L146-L155) handles nil user |
| `render 'shared/backlinks'` | [55](app/views/notes/show.md.erb#L55) | No user refs |
| `render 'shared/attachments_section'` | [56](app/views/notes/show.md.erb#L56) | No user refs |
| `render 'shared/comments_section'` | [57](app/views/notes/show.md.erb#L57) | See below |
| Report link block | [58-62](app/views/notes/show.md.erb#L58) | `@current_user && …` guard |

`shared/_comments_section.html.erb` line [14](app/views/shared/_comments_section.html.erb#L14) guards form on `@current_user`. Comment list is rendered for anon (public, expected).

**Frontmatter:** metadata only — no per-user fields.
**Actions footer:** not rendered in show; emitted elsewhere.

### `/d/:decision_id.md`

**Entry:** [app/views/decisions/show.md.erb](app/views/decisions/show.md.erb)

| Reference | File:line | Risk |
|---|---|---|
| `resource_author_md(@decision)` | [12](app/views/decisions/show.md.erb#L12) | Safe |
| `@current_user && UserBlock.between?(…)` | [109-110](app/views/decisions/show.md.erb#L109) | Guarded |
| Vote table | 107-172 | Wrapped in `@current_user &&` branch; anon sees options list only |
| `@votes.where(option: option).first` | [120-122](app/views/decisions/show.md.erb#L120) | `@votes` is nil for anon (controller returns `Vote.none` or via `current_votes` which gates on participant); structure ensures block is unreachable for anon |
| `render 'shared/backlinks'` | [180](app/views/decisions/show.md.erb#L180) | Safe |
| `render 'shared/attachments_section'` | [181](app/views/decisions/show.md.erb#L181) | Safe |
| `render 'shared/comments_section'` | [182](app/views/decisions/show.md.erb#L182) | Safe |
| Report link | [183-187](app/views/decisions/show.md.erb#L183) | `@current_user &&` |

**Frontmatter:** metadata only.
**Phase 4 assertion target:** anon markdown of an open decision contains no `accept:`/`prefer:` cells for the viewer.

### `/c/:commitment_id.md`

**Entry:** [app/views/commitments/show.md.erb](app/views/commitments/show.md.erb)

| Reference | File:line | Risk |
|---|---|---|
| `resource_author_md(@commitment)` | [21](app/views/commitments/show.md.erb#L21) | Safe |
| `render 'shared/automation_attribution'` | [36](app/views/commitments/show.md.erb#L36) | No user refs |
| `participant.user&.name \|\| 'Anonymous'` | [73-74](app/views/commitments/show.md.erb#L73) | Safe-nav |
| `render 'shared/backlinks'` | [82](app/views/commitments/show.md.erb#L82) | Safe |
| `render 'shared/attachments_section'` | [83](app/views/commitments/show.md.erb#L83) | Safe |
| `render 'shared/comments_section'` | [84](app/views/commitments/show.md.erb#L84) | Safe |
| Report link | [85-89](app/views/commitments/show.md.erb#L85) | `@current_user &&` |

Participant list shows public names — expected; participation is public.

### `/help[/:topic].md`

Zero user references across all 22 topic templates. All static documentation.

### Helpers worth flagging for Phase 4

- [`api_helper`](app/helpers/api_helper.rb) — controller-level helper that builds action descriptions. Anon should not render an "Actions" footer in markdown. Verified above that show templates do not render an actions footer block. If [`available_actions_for_current_route`](app/helpers/markdown_helper.rb) is called from layout, confirm it skips for anon.
- [`MarkdownHelper#truncate_content`](app/helpers/markdown_helper.rb#L57) — 2000-char truncation. Equal treatment for anon; no risk.

## Inventory 3 — DB mutations reachable from GET

### Controller-level

| Action | Line | Site | Write? | Anon-gated? |
|---|---|---|---|---|
| `NotesController#show` | [18](app/controllers/notes_controller.rb#L18) | `NoteReader.new(note: @note, user: current_user)` | **No** — pure in-memory query object ([note_reader.rb](app/models/note_reader.rb)) | n/a |
| `DecisionsController#show` | [86](app/controllers/decisions_controller.rb#L86) | `@participant = current_decision_participant` | **Yes — create** via [DecisionParticipantManager#find_or_create_participant](app/services/decision_participant_manager.rb) | **Gated**: [application_controller.rb:731](app/controllers/application_controller.rb#L731) requires `current_decision && current_user` — anon falls through to nil |
| `DecisionsController#show` | [102](app/controllers/decisions_controller.rb#L102) | `@votes = current_votes` | **No** — read-only AR relation, returns nil for anon ([application_controller.rb:745](app/controllers/application_controller.rb#L745)) | Gated |
| `DecisionsController#show` | [111](app/controllers/decisions_controller.rb#L111) | `DecisionAuditEntry.where(decision_id:).order(…).first` | **No** — read only | n/a |
| `CommitmentsController#show` | [16](app/controllers/commitments_controller.rb#L16) | `@commitment_participant = current_commitment_participant` | **Yes — create** via [CommitmentParticipantManager](app/services/commitment_participant_manager.rb) | **Gated**: [application_controller.rb:770](app/controllers/application_controller.rb#L770) requires `current_commitment && current_user` |
| `HelpController#*` | various | None | None | n/a |

### Before-action level (only `set_pin_vars`, `set_report_vars` write-suspicious by name)

| Helper | Definition | Write? |
|---|---|---|
| `set_pin_vars` | [app/controllers/application_controller.rb:937-942](app/controllers/application_controller.rb#L937-L942) | No — reads `is_pinned?` |
| `set_report_vars` | [app/controllers/application_controller.rb:925-927](app/controllers/application_controller.rb#L925-L927) | No — `ContentReport.where(reporter: current_user, …)` is a query; with nil reporter the WHERE clause matches nothing |

### Verified absent on GET show paths

- `CollectiveMember#touch` — only called inside [validate_authenticated_access at app/controllers/application_controller.rb:557](app/controllers/application_controller.rb#L557), which is the *authenticated* branch.
- Auto-add-to-collective (`current_collective.add_user!`) — same: only in [validate_authenticated_access at line 544](app/controllers/application_controller.rb#L544).
- `Notification` mark-as-read — not in show paths.
- Pin / unpin — POST-only routes (verified in [config/routes.rb:496, 542, 586](config/routes.rb#L496)).
- Analytics / `AuditEntry` writes — not in show paths.

### Phase 1 test (already required by plan §B Phase 1 list)

> "Anon request → no crash anywhere in the before-action chain."

Add an explicit assertion: after `GET /d/:id` and `GET /c/:id` as anon, `DecisionParticipant.count` and `CommitmentParticipant.count` are unchanged.

## Inventory 4 — Before-action chain with nil user

Declared at [app/controllers/application_controller.rb:10-22](app/controllers/application_controller.rb#L10-L22).

| Before-action | Defined | Behavior with nil `@current_user` | Verdict |
|---|---|---|---|
| `check_auth_subdomain` | [26-32](app/controllers/application_controller.rb#L26-L32) | Redirects only for auth-subdomain requests; otherwise no-op | Safe |
| `current_app` | [38-47](app/controllers/application_controller.rb#L38-L47) | Sets static constants | Safe |
| `current_collective` | [58-79](app/controllers/application_controller.rb#L58-L79) | `Collective.scope_thread_to_collective(subdomain, params[:collective_handle])`; no user dependency; default-to-main when handle missing | Safe |
| `current_tenant` | [49-56](app/controllers/application_controller.rb#L49-L56) | Reads `@current_collective.tenant`; redirects to `/404` if tenant archived | Safe |
| `current_path` | [97-106](app/controllers/application_controller.rb#L97-L106) | Builds query string | Safe |
| `current_user` | [191-199](app/controllers/application_controller.rb#L191-L199) | **Calls `validate_unauthenticated_access` transitively** for anon — this is the gate | This is where the bypass lives |
| `current_resource` | [694+](app/controllers/application_controller.rb#L694) | Resolves resource via params | Safe |
| `current_representation_session` | [606+](app/controllers/application_controller.rb#L606) | Validates rep session; returns nil for anon | Safe |
| `current_heartbeat` | [626+](app/controllers/application_controller.rb#L626) | Gated on `current_user && !main_collective` | Safe |
| `load_unread_notification_count` | [668-677](app/controllers/application_controller.rb#L668-L677) | Gated on `@current_user && current_tenant && !request.format.json?`; returns 0 for anon | Safe |
| `set_sentry_context` | [1262+](app/controllers/application_controller.rb#L1262) | Uses `@current_user&.id` safe-nav | Safe |
| `check_session_timeout` | [1118-1153](app/controllers/application_controller.rb#L1118-L1153) | Early return at [1120](app/controllers/application_controller.rb#L1120): `return unless session[:user_id].present?` | Safe |
| `check_user_suspension` | [1155-1166](app/controllers/application_controller.rb#L1155-L1166) | Early return at [1157](app/controllers/application_controller.rb#L1157): `return unless session[:user_id].present?` | Safe |
| `check_activation_gate` | [1177-1202](app/controllers/application_controller.rb#L1177-L1202) | Early return at [1182](app/controllers/application_controller.rb#L1182): `return unless human&.human?` | Safe |
| `check_stripe_billing_gate` | [1207-1241](app/controllers/application_controller.rb#L1207-L1241) | Early return at [1208](app/controllers/application_controller.rb#L1208): `return unless @current_user&.human?` | Safe |
| `check_collective_archived` | [1246-1260](app/controllers/application_controller.rb#L1246-L1260) | Redirects to `<collective>/settings` if archived; anon would then hit the auth gate again. **Plan §E flags this as "acceptable double-redirect."** | Acceptable |
| `ActionCapabilityCheck#check_capability_for_action` | [app/controllers/concerns/action_capability_check.rb:152-184](app/controllers/concerns/action_capability_check.rb#L152-L184) | Early return at [154](app/controllers/concerns/action_capability_check.rb#L154): `return unless defined?(@current_user) && @current_user.present?` | Safe |

### CSRF

`skip_before_action :verify_authenticity_token, if: :api_token_present?` at [application_controller.rb:24](app/controllers/application_controller.rb#L24). Bypass condition 4 (`request.get? || request.head?`) means non-GET cannot reach the bypass. No CSRF interaction.

### Tenant/Collective scoping

[`Collective.scope_thread_to_collective` at app/models/collective.rb:48-74](app/models/collective.rb#L48-L74) sets `Tenant.current_id` and `Collective.current_id` based purely on `request.subdomain` and `params[:collective_handle]`. Anon users get scoped identically to logged-in users on the same URL. `ApplicationRecord` default scope then auto-restricts every query.

### Rate limits

[`RateLimits` concern](app/controllers/concerns/rate_limits.rb) is included at [application_controller.rb:5](app/controllers/application_controller.rb#L5). Existing per-user rate limits won't trigger for anon (no user identity). Phase 2 adds per-IP limit on the three show actions per [plan §I](anonymous-read-access-main-collective.md#L139).

## Helpers verified safe

- [`blocked_user_ids` at app/controllers/application_controller.rb:640-666](app/controllers/application_controller.rb#L640-L666) — returns empty `Set` for nil user.
- [`resource_author_md` at app/helpers/application_helper.rb:160-173](app/helpers/application_helper.rb#L160-L173) — returns "Anonymous" for nil author.
- [`user_link_md` at app/helpers/application_helper.rb:146-155](app/helpers/application_helper.rb#L146-L155) — nil-safe.

## Surprises and risks

### A. `_options_section.html.erb` calls `@participant.authenticated?` on possibly-nil `@participant`

[decisions/_options_section.html.erb:2](app/views/decisions/_options_section.html.erb#L2) reads `!@participant.authenticated?`. For anon, `@participant` is nil from [current_decision_participant else-branch at app_controller.rb:737](app/controllers/application_controller.rb#L737). Bare `.authenticated?` on nil will `NoMethodError`.

**Phase 3 must verify**: either `@participant` is initialized to a placeholder before render, or this needs `@participant&.authenticated? != true`-style guard. **First test target.**

### B. `_options_section.html.erb` calls `can_add_options?(@participant)` with possibly-nil participant

[decisions/_options_section.html.erb:68](app/views/decisions/_options_section.html.erb#L68). Confirm `Decision#can_add_options?` accepts nil; if not, guard.

### C. `StatementEmbedComponent` receives `current_user`

[decisions/show.html.erb:142](app/views/decisions/show.html.erb#L142). Confirm the component's initializer / render doesn't dereference a nil user.

### D. `_pulse_comments.html.erb` line 16 `.blocked?` on user object

[shared/_pulse_comments.html.erb:16](app/views/shared/_pulse_comments.html.erb#L16) calls `@current_user.blocked?(commentable.created_by)`. This is inside the outer `@current_user &&` guard at line 13, but a strict re-read should confirm the branch can never be entered for anon.

### E. Help controller dynamic methods + `allows_anonymous(:index, *TOPICS)`

[help_controller.rb:31-45](app/controllers/help_controller.rb#L31-L45) defines actions dynamically via `TOPICS.each do |topic| define_method(topic) … end`. The plan §C declaration `allows_anonymous(:index, *TOPICS)` must execute *after* `TOPICS` is set (it is — `TOPICS` is a top-of-class constant). Phase 1 must include a test asserting `HelpController.allows_anonymous?(:privacy)` returns true.

### F. Pre-existing anon login CTAs

Three partials already render explicit "Log in to …" branches for anon users:
- [notes/_confirm.html.erb:107-125](app/views/notes/_confirm.html.erb#L107-L125)
- [decisions/_options_section.html.erb:3-5](app/views/decisions/_options_section.html.erb#L3-L5)
- [commitments/_join.html.erb:76-79](app/views/commitments/_join.html.erb#L76-L79)

This is dead code today (anon never reaches show), but it means Phase 3's `shared/_login_to_act.html.erb` may have less work than expected. Decide whether to consolidate these three into the new shared partial or leave them in place. Recommendation: consolidate to keep CTA copy uniform.

### G. Default-scope leakage check

Per [plan §"Risks to verify"](anonymous-read-access-main-collective.md#L274): grep show paths for `unscope_collective`, `tenant_scoped_only`, `for_user_across_tenants`.

```
$ rg "unscope_collective|tenant_scoped_only|for_user_across_tenants" app/controllers/{notes,decisions,commitments,help}_controller.rb app/views/{notes,decisions,commitments,help}/
# (none)
```

Clean.

### H. `validate_unauthenticated_access` is not a `before_action`

It runs inside `current_user`. Implication: any controller that overrides `current_user` (none currently — verified by `grep -n "def current_user" app/controllers/**/*.rb` returning only the base definition) would bypass the gate entirely. The macro check still belongs on the base class because the bypass adds a `return if` *inside* the base method, but Phase 5's route sweep is the real safety net.

## What Phase 1 should test (drawn from this audit)

- `Tenant#public_main_collective?` for empty / present / absent / case-mixed / whitespace inputs.
- `ApplicationController.allows_anonymous?` returns false on base, true after declaration, **does not inherit to a subclass**, isolation between sibling controllers.
- `request.format.symbol == :md` for `Accept: text/markdown`.
- The 6-condition bypass: matrix of public/private tenant × allowlisted/not × main/non-main collective × GET/POST × HTML/MD/JSON.
- After anon `GET /d/:id`, `DecisionParticipant.count` unchanged.
- After anon `GET /c/:id`, `CommitmentParticipant.count` unchanged.
- `HelpController.allows_anonymous?(:privacy)` true.
- `HelpController.allows_anonymous?(:api)` true (feature flag handles availability separately).

## What Phase 3 should re-verify per partial

- [decisions/_options_section.html.erb](app/views/decisions/_options_section.html.erb) — nil `@participant` handling at line 2 and 68 (Surprise A, B)
- [decisions/show.html.erb:142](app/views/decisions/show.html.erb#L142) — `StatementEmbedComponent` with nil user (Surprise C)
- [shared/_pulse_comments.html.erb:16](app/views/shared/_pulse_comments.html.erb#L16) — confirm unreachable for anon (Surprise D)
- Layout `_top_right_menu.html.erb` else-branch styling for anon
- Resource sidebar partials reachable via `SidebarComponent` with `@sidebar_mode = "resource"`
- Consolidation of three existing anon CTAs into `shared/_login_to_act.html.erb` (Surprise F)

## Phase 1 corrections to this audit (post-implementation)

Phase 1 implementation surfaced nil-user issues this audit either missed or deferred. Recording so the audit stays honest:

1. **Missed: `Pinnable#is_pinned?(user:)` crashes on nil user.** Phase 0 wrote "`set_pin_vars` ... query only, no write. Safe." Wrong — `Pinnable#is_pinned?` calls `user.has_pinned?(self)` and explodes on nil. Phase 1 fixed by early-returning from `set_pin_vars` with `@is_pinned = false` when user is nil. The view's `show_pin = @current_user && …` guard means anon never sees the pin UI anyway, so `@is_pinned = false` is sound.

2. **Missed: `current_votes` returns nil for anon, controller called `.any?` on it.** Phase 0 said "@votes is nil for anon — surrounding template already routes anon through a read-only branch." Partially right at the view layer, but the controller at `decisions_controller.rb:103` had `@current_user_has_voted = @votes.any?` before any view ran. Phase 1 changed `current_votes` to return `Vote.none` instead of nil, which `.any?` handles.

3. **Surprise A confirmed: `_options_section.html.erb:2` crashed on nil `@participant`.** Fixed by changing `<% if !@participant.authenticated? %>` to `<% if @participant.nil? || !@participant.authenticated? %>`. The "anon → login CTA" branch was already in place; it just wasn't reachable for nil participant.

4. **Sorbet sigs needed widening (not flagged by Phase 0).** Several methods had `User` / `T.any(X, User)` sigs that rejected nil at runtime even when the implementation could have handled nil:
   - `NoteReader#initialize(user: T.nilable(User))`
   - `Note#user_can_edit?(user: T.nilable(User))`
   - `Decision#can_add_options?`, `#can_update_options?`, `#can_delete_options?`, `#can_edit_settings?`, `#can_close?` → `T.nilable(T.any(DecisionParticipant, User))`
   - `Commitment#can_edit_settings?`, `#can_close?` → same pattern

5. **Dead `Decision#public?` stub deleted** as planned (was at decision.rb:188).

Phase 3 still needs to do the full per-partial view sweep — Phase 1 only fixed the entry-point crashes that integration tests surfaced. Anything inside a deeper render branch that wasn't exercised by the bypass tests is still untested for nil-user.

## On merge

Move this file to `.claude/plans/completed/YYYY/MM/`.
