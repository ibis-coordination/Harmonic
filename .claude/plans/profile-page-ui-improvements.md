# Profile page UI improvements

Branch: `profile-page-ui`. Seven phases, one PR each, in the order listed.

Pins and bulk tune-in get separate spike docs (`spike-pins-on-profile.md`, `spike-bulk-tune-in.md`) and are out of scope here.

## Decisions

- Bio / location / website live on `TenantUser` (per-tenant).
- Profile pic editor: modal with crop + preview, reusing `HasImage#cropped_image_data=`.
- Profile links always point to top-level `/u/:handle` everywhere.
- Default tab after P4 (Posts split) is **Posts**.
- Markdown view stays inline (no `?tab=` behavior).
- Tune-in button is **hidden** when blocked, not disabled.

## Out of scope

AI-agent-specific tweaks, mobile redesign (just don't regress), anything `Pinnable`.

---

## P1 — Remove Social Proximity from the profile page

UI surface only. Delete the accordion, partial, `load_proximity_connections` (`users_controller.rb` ~715), and `@proximity_users` references. HTML + markdown views both. Remove visibility tests for the removed section.

**Keep:** `SocialProximityCalculator`, `User#social_proximity_to`, `User#proximity_scores`, `User#cached_proximity_scores`, `User#most_proximate_users`, the `FeedBuilder#proximity_scores:` ranking path. These are general primitives that future features will build on.

---

## P2 — Profile links → top-level `/u/:handle` ✅ shipped

Render sites swapped (`shared/_team.html.erb`, `collectives/members.html.erb`). All other byline / list / mention sites already used `user.path`. No callers of `CollectiveMember#path` remained, so the method was deleted along with its tests. The `/c/:handle/u/:user_handle` route still resolves but is no longer linked from any view — leave for a future routes cleanup.

**Test:** GET collective members page → `a.pulse-participant-name` links to `/u/:handle`, never to a collective-scoped URL.

---

## P3 — Tabs instead of accordions ✅ shipped

Tabs at end of phase: **Activity (default), Lists, Common Collectives**. P4 will add **Posts** and flip default.

- Visibility implemented per plan: Common Collectives tab only when viewing someone else AND count > 0. Lists always visible (empty state). Activity always visible.
- `TabsComponent` extracted (with `Tab` value class); CSS for `.pulse-tabs` / `.pulse-tab` / `.pulse-tab-active` lives in `_components.css`. Migrated `user_lists/show.html.erb` to use it.
- Controller: `@active_tab` from `params[:tab]`. Split into `load_profile_header_data` (always) and `load_profile_<tab>_data` (active tab only on HTML; all on markdown). P6 will extend the header loader with bio/location/website.
- Markdown view unchanged — preserves inline sections, ignores `?tab`.
- Pagination unchanged from today.

---

## P4 — Split Recent Activity into Posts + Activity ✅ shipped

- **Posts**: notes with `subtype = "post"`. Default tab (flipped from Activity).
- **Activity**: everything FeedBuilder produces today minus post-subtype notes (i.e., non-post notes + decision/commitment creations).
- Per-tab loaders: `load_profile_posts_data` (sets `@posts_feed_items`), `load_profile_activity_data` (sets `@activity_feed_items`). Load only the active one in HTML; markdown calls both.
- Markdown: two consecutive sections (`## Posts`, `## Activity`), parallel to HTML tabs.

**Tests** in `users_controller_test.rb`:
- Posts tab renders only post-subtype notes; Activity excludes posts.
- Default tab is Posts.
- Partition invariant: `posts ∪ activity == FeedBuilder(user)` baseline, and no overlap.
- Markdown renders both sections inline.

---

## P5 — Easier tune-in from list pages and notifications ✅ shipped

Tune-in button on three surfaces:
1. **List members tab** rows (`user_lists/show.html.erb`, `?tab=members`).
2. **Tune-in notification** rows ("X tuned in to you"). Notification page renders per-request — no Turbo Frame needed; button reflects current state via the controller's batch-loaded state ivars.
3. **Other user's mutuals page** (`/u/:handle/mutuals`). Skipped on viewer's own mutuals page (every row is already reciprocal).

In all cases: hidden when `viewer == target` or either side blocks.

**Building blocks added:**
- `app/views/shared/_tune_in_button.html.erb (viewer, target, on_list, blocked)` — wraps `AjaxToggleButtonComponent`. Renders nothing for the anon/self/blocked cases.
- `TuneInState.compute(viewer:, target_ids:, tenant:)` (PORO at `app/services/tune_in_state.rb`) — returns `(on_list_ids, blocked_pair_ids)` as Sets.
- `UserBlock.blocked_pair_user_ids(viewer_id, target_ids)` — symmetric one-query batch lookup.

Each surface's controller calls `TuneInState.compute(...)` once with the rendered users and stashes the result in `@tune_in_state`; the view does O(1) Set lookups per row.

**Tests:** state matrix per surface (Tune in / Tuned in / self / blocked); button absent on viewer's own mutuals page; model tests for `UserBlock.blocked_pair_user_ids`.

---

## P6 — TenantUser profile fields: bio, location, website ✅ shipped

**Schema:** migration `20260609000000_add_profile_fields_to_tenant_users` added `bio:text`, `location:string`, `website:string` to `tenant_users`, all nullable.

**Validations on `TenantUser`:** `bio ≤ 500` chars (`BIO_MAX_LENGTH`), `location ≤ 100` chars (`LOCATION_MAX_LENGTH`), website rejects anything that isn't an http/https URL with a hostname. Website rendered with `rel="nofollow noopener" target="_blank"`.

**Views:** new `.pulse-user-profile-info` block between the header and the tab nav, hidden when blocked-either-way OR when all three fields are blank. Markdown view interpolates the same fields inline. Settings form adds bio (textarea, `maxlength` capped) / location / website (`type="url"`).

**Controller:** `update_profile` writes the three fields on the per-tenant TenantUser via a `params.key?(:field)` guard so absent fields stay untouched and empty strings clear. Validation errors flash via `:alert` and redirect back.

**Tests** in `tenant_user_test.rb` (validations) and `users_controller_test.rb` (renders, settings form, update_profile happy + invalid-website paths).

---

## P7 — Profile pic editor (modal)

Owner clicks avatar → modal with file picker + crop + preview → Save → Turbo Stream swaps the avatar.

**First step:** grep for an existing cropper modal on the settings page. If it already hits `cropped_image_data=`, add a profile-page trigger that opens the same modal — no new endpoint, no new lib. Bullets below assume nothing reusable.

- Stimulus controller `profile_pic_modal_controller.ts` manages the cropper and submits the data URL.
- Cropper lib: cropperjs (BSD-3) if nothing vendored.
- Modal: `<dialog>` next to the avatar, gated on `current_user.can_edit?(@showing_user)`. Click-avatar or pencil overlay to open.
- POST `cropped_image_data` to existing or new endpoint → Turbo Stream replaces avatar `<div>`.

**Tests:** upload endpoint (auth, size guard, happy path); Vitest unit for the Stimulus controller (open/cancel/submit).

**Risk:** medium.
- `<dialog>` + Turbo Drive interactions (focus trap, history, modal across navs).
- iOS Safari `<dialog>` support varies — verify or fall back to div.
- New JS dep (cropperjs) if needed.

---

## Open questions

1. **Cropperjs vendor:** add as npm dep, or preferred existing library?
2. **Bio length cap:** 500 chars OK?
