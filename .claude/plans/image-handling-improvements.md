# Image Handling Improvements

Three separate-but-interrelated improvements to how Harmonic handles images: profile-pic optimization, images as first-class note content, and per-user unique default avatars. Phase 1 establishes the image-processing pipeline that Phase 2 builds on; Phase 3 is independent.

## Current State

- **Profile pics** (User, Collective): [HasImage](../../app/models/concerns/has_image.rb) declares `has_one_attached :image`. `image_path` returns the raw blob URL — **no variants, no resizing**. `cropped_image_data=` writes cropper output as JPG without bounding the source size.
- **`image_processing` gem is commented out** in [Gemfile:50](../../Gemfile#L50).
- **Default avatar** is a single static `public/placeholder.png`. [AvatarComponent](../../app/components/avatar_component.rb) already falls back to initials in a styled div when `image_url` is blank-or-placeholder, so most users already see initials, not the PNG. But the background color is the same for everyone — no per-user uniqueness.
- **Note attachments** flow through polymorphic [Attachment](../../app/models/attachment.rb) via the [Attachable](../../app/models/concerns/attachable.rb) concern. Images, PDFs, and text are treated identically — same model, same 10 MB cap, same partial. Display partials inline `<img>` for image content types but at original blob size.
- **Frontend**: [image_cropper_controller.ts](../../app/javascript/controllers/image_cropper_controller.ts) wraps cropperjs for profile pics. No drag/drop, paste-from-clipboard, or upload progress anywhere. Note editor has no image-specific affordance.
- **Storage**: ActiveStorage with local disk in dev, DigitalOcean Spaces in prod ([config/storage.yml](../../config/storage.yml)).

## Goals & Non-Goals

**Goals**
1. Stop shipping multi-MB originals for 48px avatars
2. Make images in notes feel like content (inline gallery, alt text, drag/drop), not file attachments
3. Replace the single shared placeholder with a per-user unique default avatar

**Non-Goals**
- Rich-text editor / ActionText migration
- Video or audio media (defer; the model should leave room but not implement)
- CDN/edge transformation (Cloudflare Images, imgproxy) — possible later optimization
- EXIF GPS stripping as a separate feature (it falls out of the variant pipeline since variants are re-encoded)

## Locked Decisions

| Question | Decision | Rationale |
|---|---|---|
| Default avatar style | Initials on procedurally-colored circle | Uniqueness via color hash, identity via initials, matches existing fallback, no storage cost |
| `MediaItem` vs. extend `Attachment` | New `MediaItem` model | Clean separation of image-specific concerns; bounded duplication |
| Variant generation | Preprocessed (background job) | Predictable first-paint; storage cost is negligible |
| Legacy image attachments on notes | Migrate to `MediaItem` | One code path long-term; the migration itself is routine |
| Feature flag scope | `MediaItem` always enabled; `Attachment` stays gated by `file_attachments` flag | Image-in-note is now a core content capability, not an optional feature |
| Animated GIFs | Allow; static first-frame for thumbnails, animated at `:large` | Modern user expectation |
| Storage quota | `MediaItem` byte_size counts against the same per-collective `file_upload_limit` as attachments | One pool, simpler accounting |
| `<picture>` WebP+JPEG fallback | Skip | >97% of traffic supports WebP |

---

## Phase 1 — Profile Pic Optimization

Establishes the image-processing pipeline. Smallest scope, unblocks Phase 2.

### Changes

1. **Enable `image_processing` gem** ([Gemfile:50](../../Gemfile#L50)). Use libvips backend (faster, lower memory than ImageMagick). Verify libvips is installed in the web container Dockerfile; add if missing.
2. **Define variants on `HasImage`** ([app/models/concerns/has_image.rb](../../app/models/concerns/has_image.rb)) with `preprocessed: true`:
   - `:icon` — 48×48, square-cropped, WebP, quality 80
   - `:thumbnail` — 128×128, square-cropped, WebP, quality 80
   - `:display` — 512×512, contain (no crop), WebP, quality 85
3. **Add `image_url(variant:)` method** that returns the variant URL via `rails_representation_url`. No-argument version returns `:display` for backward compatibility.
4. **Update `AvatarComponent`** ([app/components/avatar_component.rb](../../app/components/avatar_component.rb)) to map `@size` → variant. Default `nil` → `:icon` (most uses are small).
5. **Bound source on upload**: in `cropped_image_data=` and `image_url=`, resize incoming images to a max of 1024×1024 before attaching. Prevents 50 MB phone photos sitting in storage as "originals."
6. **Collective profile pics**: same concern, no additional changes.

### Tests
- `has_image_test.rb` (new or extended): variant URLs produced, source >1024 px resized down, preprocessing job enqueued on attach.
- `avatar_component_test.rb`: extend existing tests to assert URL contains expected variant key.
- Sorbet: regen RBIs with tapioca for new variant methods.

### To verify early
- libvips available in the web container — confirm in Dockerfile, add if missing.

---

## Phase 2 — Images as First-Class Note Content

The bulk of the work. Separates "media in a note" from "file attached to a note," and migrates legacy image attachments into the new model.

### Status — implemented on branch `media-items-phase-2`

**Security & bug fixes applied after self-review (see commit history):**
- WebP magic-byte check now requires both `RIFF` (offset 0) and `WEBP` (offset 8) so RIFF-container imposters (WAV/AVI) are rejected.
- `show.md.erb` escapes `]`, `(`, `)`, `\`, `*`, `_`, `` ` ``, `<`, `>` in alt_text/caption and collapses newlines, blocking markdown injection in the AI-agent view.
- `MediaItemsController#create` rescues `MessageVerifier::InvalidSignature` and returns 422 instead of 500.
- `attach_pending_media!` (new-note flow) now enforces the per-collective storage quota and caps the per-request entry count at 50.
- `MediaItem` has explicit length limits: alt_text ≤ 500, caption ≤ 5000.
- `MediaItem#url(variant:)` raises `ArgumentError` for unknown variants.
- `DirectUploadsController` enforces session timeout + rejects suspended users in addition to "exists".
- Client-side pre-checks file size before kicking off direct upload; uploader partial uses regular ERB (auto-escaped) instead of raw `<%==`.
- Rake task gained `THROTTLE_EVERY` / `THROTTLE_SECONDS` / `VALIDATE` knobs to space out Sidekiq variant jobs and optionally re-verify each migrated row.


| Plan item | Shipped | Deferred |
|---|---|---|
| `MediaItem` model + table | ✓ | — |
| Variants (:thumbnail 250, :medium 800, :large 1600) | ✓ | — |
| `HasMagicByteValidation` shared concern; `Attachment` refactored to use it | ✓ | — |
| `Note has_many :media_items` polymorphic association | ✓ | — |
| `Collective#file_storage_usage` sums both Attachment + MediaItem | ✓ | — |
| `MediaItemsController` (create/update/destroy/reorder) + nested routes | ✓ | — |
| Display partial `shared/_note_media.html.erb` with grid + srcset | ✓ | — |
| Lightbox (`lightbox_controller.ts`, Esc/click-outside, focus management) | ✓ | — |
| Editor partial `shared/_note_media_uploader.html.erb` + `note_media_uploader_controller.ts` (drag/drop + paste + picker + per-file progress + alt text) | ✓ | — |
| Direct upload to ActiveStorage; `DirectUploadsController` hardened: auth required + 25 MB cap initializer | ✓ | — |
| Markdown emission (`![alt](url)` for AI-agent path) | ✓ | — |
| Rake task `images:migrate_note_attachments` with DRY_RUN, idempotency, batch logging | ✓ | — |
| Tests: model (13), controller (8), storage quota (1), migration rake (3) — 25 new model/controller/integration tests; all 200 assertions green | ✓ | — |
| Sorbet RBIs regenerated; new shim for `ActiveStorage::Attached::One#variant`/`preview`/`representation` | ✓ | — |
| In-editor reorder via drag | — | Future iteration — current UX is upload-and-go; explicit reorder UI deferred since most notes have ≤3 images. Server endpoint `PATCH /n/:id/media_items/reorder` is built and tested. |
| `allowed_attachment_categories` default change to `%w[pdfs text]` for new tenants | — | Deferred — current default still includes `"images"`. Harmless: no image will reach `Attachment.validate_file` from a note flow since the editor now routes images through MediaItem. Will tighten in a follow-up to avoid surprise on Decision/Commitment attachment paths (which still accept images via Attachment for now). |
| Cleanup of `_pulse_attachments`/`_attachments_section` to stop branching on image content type | — | Deferred until after the data migration runs in prod. While both code paths coexist, the partials must still handle image-type Attachments correctly. |
| Component test for grid + Playwright E2E for editor flow | — | Deferred — model/controller coverage is solid; visual + E2E lift adds scope without changing behavior. Open as follow-up. |

### Model: `MediaItem` (new)

Polymorphic, parallel to `Attachment`, image-only:

```
media_items
  id, tenant_id, collective_id
  mediable_type, mediable_id     (polymorphic, currently just Note)
  content_type, byte_size
  alt_text:string                # accessibility, optional but encouraged
  caption:text                   # optional display caption
  display_order:integer          # for in-note ordering
  width:integer, height:integer  # cached from analysis
  created_by_id, updated_by_id, timestamps
```

`has_one_attached :file` with image variants (`:thumbnail` 250×250, `:medium` 800px-wide, `:large` 1600px-wide), `preprocessed: true`. Image-only content type whitelist (image/png, image/jpeg, image/gif, image/webp). Magic-byte validation; extract the existing logic from `Attachment` into a shared `Concerns::HasMagicByteValidation` so both models use the same code.

### Note integration

- `Note has_many :media_items, -> { order(:display_order) }, as: :mediable, dependent: :destroy`
- `Note#has_media?`, `Note#media_items` available in views.
- Existing `has_many :attachments` through `Attachable` stays untouched for non-image attachments.

### Feature flag separation

This is a meaningful product change: previously, all uploads (images and files alike) were gated by the `file_attachments` flag on `Tenant` ([app/models/tenant.rb:190](../../app/models/tenant.rb#L190)). After Phase 2:

- **`MediaItem` is always enabled** — every tenant can add images to notes regardless of `file_attachments_enabled?`. No flag check on the `MediaItem` model, controller, or upload UI.
- **`Attachment` stays gated** — file uploads (PDFs, text) still require `tenant.file_attachments_enabled?`. The existing check in `AttachmentsController` and any model-level guards remain.
- **`allowed_attachment_categories`** setting: `"images"` becomes dead config for the Note flow (images no longer flow through `Attachment`). Default changes to `%w[pdfs text]` for new tenants. Existing tenants keep their current setting — harmless, since no image will reach `Attachment.validate_file` for a note. No data migration needed for the setting.
- **Storage quota**: `Collective#file_storage_usage` (currently sums `Attachment.byte_size`) is updated to also sum `MediaItem.byte_size`. Both kinds of upload count against the same `file_upload_limit`. Media uploads succeed regardless of the `file_attachments` flag, but they still fail if the collective is over quota.
- **UI implication**: the note editor exposes the image upload affordance (drag/drop zone, picker, paste) unconditionally. The file-attachment affordance is hidden when `tenant.file_attachments_enabled?` is false. Two separate UI regions, two separate visibility rules.

### Views

- New partial `shared/_note_media.html.erb`: grid layout (1-col for single, 2-col for 2-4, 3-col for more), lazy-loaded `<img>` with `srcset` from variants, lightbox on click.
- Pulse note partial renders media above attachments section.
- Markdown rendering for AI agents emits `![alt](url)` per media item.
- After migration: `_attachments_section.html.erb` / `_pulse_attachments.html.erb` no longer need to render images, since image-content-type attachments no longer exist on notes. Simplify accordingly.

### Frontend (editor)

- Stimulus controller `media_uploader_controller.ts` on note form:
  - File picker button + drag/drop zone + clipboard paste handler
  - Per-file progress
  - Reorder via drag (sortable.js or HTML5 DnD)
  - Alt-text input per uploaded image
- Direct upload to ActiveStorage (confirm `@rails/activestorage` is in the stack) to avoid round-tripping file bodies through Rails.
- The Phase 1 image cropper is **not** reused here — note media is "drop and go," cropping is a profile-pic-only ritual.

### Migration of existing image attachments

One-time data migration that copies image-content-type `Attachment` records on Notes into `MediaItem`:

1. For each `Note` with image-content-type attachments (sorted by `attachments.id`):
   - For each such `Attachment`, build a `MediaItem` with matching `tenant_id`, `collective_id`, `created_by_id`, `updated_by_id`, `content_type`, `byte_size`.
   - Set `display_order` from the sorted index.
   - `alt_text` and `caption` blank.
   - Re-attach the **same blob** using `media_item.file.attach(attachment.file.blob)` — creates a new `ActiveStorage::Attachment` row pointing at the existing blob; no file copy.
   - `attachment.destroy!` — drops the original join row; blob persists because `MediaItem` now references it.
2. Variant preprocessing triggers automatically per `MediaItem` via `preprocessed: true`. For large backfills, throttle the job queue to avoid Sidekiq pile-up.
3. Idempotency guard: skip if a `MediaItem` with the same `mediable` and the same blob already exists. Allows safe re-run.
4. Run as a Rake task (`rake images:migrate_note_attachments`), not a Rails migration — it's data, can be slow, must be observable.
5. On production: dry-run first (count records, no writes), then run in batches with a heartbeat log.

### Tests
- `media_item_test.rb`: validation (content type, magic bytes, size), variant generation, alt text, ordering.
- `note_test.rb`: `media_items` association, dependent destroy.
- Component/system test for grid rendering and lightbox.
- E2E (Playwright) for the editor: drag-drop, paste, reorder, alt-text.
- Migration test: fixture Note with 3 image + 1 PDF attachment → 3 `MediaItem` records in upload order, PDF remains as `Attachment`, blobs unchanged, idempotent on re-run.
- Feature-flag test: with `file_attachments_enabled?` false, media uploads succeed and editor shows media affordance; attachment uploads fail and editor hides file affordance.
- Quota test: `Collective#file_storage_usage` sums both `Attachment` and `MediaItem` bytes; media upload fails when the combined total exceeds `file_upload_limit`.

### To verify before shipping
- Anywhere in the codebase that queries `Attachment` by image content type (search filters, exports, agent API) — grep and update to also/instead query `MediaItem`.
- Note serializers/markdown renderers updated to include media_items.

---

## Phase 3 — Per-User Unique Default Avatars

Simplest of the three phases. The existing `AvatarComponent` already renders initials when no image is attached; we just make the background color unique per user.

### Changes

1. **Add `avatar_color` to the `HasImage` concern** with an overridable `avatar_hue_range` hook. Derive a stable HSL hue from a hash of `id`. Pure function, no storage. Fixed saturation/lightness for readable contrast with white initials text.
   - `hue = avatar_hue_range.first + (Digest::MD5.hexdigest(id.to_s)[0, 8].to_i(16) % range_size)`
   - `"hsl(#{hue}, 55%, 45%)"`
   - User overrides `avatar_hue_range` → `(0...180)`; Collective overrides → `(180...360)`. Visually distinct in mixed lists.
2. **Update `AvatarComponent`**: render the avatar div with inline `style="background-color: <avatar_color>"`. Replaces the uniform `background: var(--color-fg-default)` from CSS for every avatar.
3. **Add `ApplicationHelper#inline_avatar`**: renders either an `<img>` (when image attached) or a colored `<span>` with initials. Drop-in replacement for bare `<img src=...>` tags. Both branches share an `inline-avatar` CSS class so styles can target either element type.
4. **Add `shared/_avatar_div` partial**: renders the wrapping-div + initials + optional image pattern. Used for the existing `.pulse-author-avatar`/`.pulse-avatar` markup pattern. Applies `avatar_color` to the wrapping div so the image (when present) overlays a per-record color background.
5. **Update `ProfilePicComponent`**: always renders (when user present); shows colored initials when the user has no image; same treatment for parent-overlay badge on AI agents.
6. **Update `_profile_image_upload.html.erb`**: shows colored initials in the upload preview when no image yet.
7. **`HasImage#image_path` returns `nil`** when no image attached. `image_path_no_placeholder` removed (no longer needed; was only used to differentiate from the placeholder fallback).
8. **Migrate all direct `<img src=...>` callers**: tenant admin dashboard, user show/settings, proximity connections, sidebars, history log, collective list/title/breadcrumbs, AI agent index/run views, team partial. Each now uses `inline_avatar` or `avatar_div` partial.

### No storage, no backfill, no after_create
The result is computed at render time, so there's nothing to generate, store, or migrate. Every existing user and collective automatically gets a unique color on next render.

### `public/placeholder.png` retained as a file
Not referenced by any view code after this change, but the file stays in `public/` to avoid breaking any external bookmarks or cached responses. Can be deleted in a future cleanup.

### Tests
- `avatar_color` is deterministic: same id → same color across calls.
- `avatar_color` for User vs. Collective falls into the expected hue range.
- `avatar_component_test.rb`: when no image attached, rendered HTML includes the user's `avatar_color` in inline style and the correct initials.
- Snapshot/visual check (manual): a list of users renders with visually distinct colors.

### Edge cases
- Anonymous/system users with no displayable initials — already handled by current `?` fallback. Pick a neutral gray for those.
- Color accessibility: ensure WCAG contrast against white text. Fix saturation/lightness; only vary hue.

---

## Implementation Order

1. **Phase 3** — quick win, no dependency on the rest. Ships cosmetic uniqueness in a small PR.
2. **Phase 1** — image-processing infrastructure. Independent improvement; unblocks Phase 2.
3. **Phase 2** — biggest scope: new model, new UI, drag/drop, lightbox, migration. Builds on Phase 1's variant pipeline and processing setup.

Each phase is independently shippable and testable.

## Risks & Open Concerns

- **libvips in container**: if not present in the web Dockerfile, Phase 1 needs a Dockerfile change and a rebuild. Verify before starting Phase 1.
- **Phase 2 migration on production**: data migration on potentially many notes. Dry-run first (count + log), then run in batches with throttling. Blobs are not duplicated (we re-attach existing blobs), so storage doesn't double during migration.
- **Existing cropper UX**: Phase 1 caps source size at 1024×1024 before storing. Verify the crop UX still feels right when very large source images are downsized before cropping.
- **Storage growth from variants**: preprocessed variants on every user's avatar and every note image multiply blob count by ~4. For DigitalOcean Spaces this is bounded and predictable; flag if cost monitoring shows anything unexpected after Phase 1 ships.
- **Color palette tuning for Phase 3**: HSL hue alone gives 360 distinct colors but some hue ranges may clash with the Harmonic palette. May need a curated palette + index-by-hash instead of free hue. Lock the algorithm in PR review against actual app screenshots.
