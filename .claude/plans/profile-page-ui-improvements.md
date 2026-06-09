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

## P4 — Split Recent Activity into Posts + Activity

- **Posts**: notes with `subtype = "post"`. New default tab.
- **Activity allow-list:** notes with subtype in `["reminder", "table", "comment", "statement"]`; decision activity (votes, creations) by the showing user; commitment activity (joins, creations) by the showing user; `user_list_member.created` events by the showing user. Anything else FeedBuilder surfaces → confirm at implementation and add here.
- Two scopes: `posts_feed_items_for(user)`, `activity_feed_items_for(user)` (everything FeedBuilder produces today minus post-subtype notes). Load only the active one.
- Markdown: two consecutive sections, parallel to HTML tabs.

**Tests:** posts shows only post notes; activity excludes post notes; no item in both. Completeness: `posts ∪ activity == FeedBuilder.feed_items_for(user)` baseline (call the existing method directly), no overlap. Default-tab flip: GET `/u/:handle` renders Posts.

---

## P5 — Easier tune-in from list pages and notifications

Add tune-in button on three surfaces:
1. **List members tab** rows.
2. **Tune-in notification** (X tuned in to you) — "Tune in back" button. **Prereq:** confirm whether notification HTML is render-time or dispatch-time. Dispatch-time → button must be a Turbo Frame that re-evaluates, otherwise stale state. Resolve before tests.
3. **Someone else's mutuals page** (`/u/:handle/mutuals` where `:handle != current_user`). Skip on viewer's own mutuals page — every row is already reciprocal.

In all cases: hidden when viewer == target or either side blocks.

**Component:** wrap `AjaxToggleButtonComponent` in `shared/_tune_in_button.html.erb (viewer, target)`.

**Batch loading (read-only, no lazy create on GET):**
```ruby
viewer_primary_list_id = UserList.tenant_scoped_only(tenant.id)
  .where(owner_id: viewer.id, is_primary: true, deleted_at: nil).pick(:id)
viewer_list_member_user_ids = viewer_primary_list_id ?
  UserListMember.where(user_list_id: viewer_primary_list_id, user_id: shown_ids).pluck(:user_id).to_set :
  Set.new
blocked_pair_ids = UserBlock.between_pairs(viewer.id, shown_ids)  # add scope if missing; symmetric
```
Partial reads from the sets — no per-row queries.

**Tests:** state matrix per surface (tune-in / Tuned in / self / blocked); button absent on viewer's own mutuals page; click → membership created; N+1 regression (query count constant in N).

---

## P6 — TenantUser profile fields: bio, location, website

**Schema:** migration adds `bio:text`, `location:string`, `website:string` to `tenant_users`, all nullable.

**Validations:** bio ≤ 500 chars, location ≤ 100 chars, website HTTP/HTTPS only (`HasImage#parse_safe_external_uri`-style scheme check). Render website with `rel="nofollow noopener"`.

**Views:** new "Profile" block above the tab nav, below the header. Hidden when blocked-either-way OR when all three fields are blank. Markdown gets the same fields inline. Settings page adds bio (textarea) / location / website fields.

**Controller:** permit the three fields on the existing settings update permit list. API serializer exposes read-only.

**Tests:** validation tests (length, URL scheme); settings update persists each field; HTML + markdown render; blocked-either-way hides the block.

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
