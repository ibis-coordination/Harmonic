# Learnings from the first UserList attempt (rolled back)

Captured before resetting the `user-lists` branch. The Twitter-follow-style
framing was the wrong shape for Harmonic; we restarted under an
addressable-subgroup framing with primary lists. These notes are the durable
knowledge that should survive the rollback.

## Codebase tribal knowledge

1. **`@global_collective` ≠ `@tenant.main_collective`** in test fixtures.
   Controllers routing under `/u/:handle/...` resolve `current_collective` via
   subdomain → main_collective. Tests must use `@tenant.main_collective` as the
   collective for resources scoped to the tenant root. Cost ~20 min debugging.

2. **TenantUser handles derive from `user.name.parameterize`**. The default
   `create_user` helper sets `name: "Test User"` → every user collides on
   handle "test-user". Always pass unique `name:`.

3. **Route param naming collisions with body params.** When the URL has a param
   `:slug` and the action body also wants `slug:`, Rails merges them with
   route-param precedence (or unspecified-by-version) and the body value is
   silently ignored. Use a distinct URL param name when the body needs the same
   key. (Mooted by switching to `truncated_id` in v2.)

4. **Static route segments must precede dynamic `:param`** segments for Rails
   to match them. Order matters. (Mooted by `truncated_id` since 8-hex never
   collides with static segments.)

5. **Markdown 404 lives at `shared/404`** — `render "shared/404", status:
   :not_found`. No `<controller>/404.md.erb` exists.

6. **Frontmatter auto-renders actions** via
   `available_actions_for_current_route` in the layout. Templates should NOT
   duplicate them in the body.

7. **`required:` in action param definitions defaults to true** when missing
   (`required: param[:required] != false`). Optional params must be explicitly
   `required: false`.

8. **AI agents have two-layer capability gating**:
   `CapabilityCheck.AI_AGENT_GRANTABLE_ACTIONS` (global allowlist) + each
   agent's `agent_configuration["capabilities"]` (per-agent allowlist set by
   owner). New actions need both.

9. **`attr_readonly` raises `ActiveRecord::ReadonlyAttributeError`** on update
   attempts; doesn't silently ignore. Tests must `assert_raises`.

10. **`build_authorization_context`** in `markdown_helper.rb` hardcodes
    `resource: @note || @decision || @commitment` and `target_user:
    @showing_user`. New resource types don't fit cleanly into the frontmatter
    authorization filter; permissive defaults mask this in the listing case.

11. **MCP for end-to-end testing is disproportionately valuable** — it
    surfaced the agent-capability gating AND the `required: true` defaulting
    that unit tests missed. Lean on it once schema is stable.

12. **Dev app caches `ACTION_DEFINITIONS` / `@@actions_by_route`**. `touch
    tmp/restart.txt` usually works; sometimes need `docker compose restart
    web`.

13. **Rubocop autofix can mangle Sorbet sigs** — particularly anonymous block
    forwarding (`&`) vs explicit `&block`. After autofix, re-check Sorbet.

14. **`belongs_to :tenant`, `belongs_to :collective` must be explicit** on
    every model even though scoping is automatic via ApplicationRecord. Sorbet
    needs them to type-check `record.tenant` / `record.collective` access.
    Regenerate RBI with `tapioca dsl ModelName` after.

15. **`UserBlock.between?(a, b)` uses default_scope** → automatically
    tenant-scoped. Convenient.

16. **`SoftDeletable`** requires a `content_snapshot` method override; adds
    `deleted_at` / `deleted_by_id` columns; default-scopes to not-deleted.

## Design lessons

1. **Twitter's "subscribe to a list" has no Harmonic home.** No global feed for
   list-timeline to slot into. Pulse is per-collective. Drop subscriber concept
   entirely.

2. **`Linkable` inclusion without parser extension is half-baked.** The
   LinkParser regex only knows `/n/`, `/c/`, `/d/`, `/r/` shapes. Don't include
   Linkable until either the parser is extended OR there's a concrete consumer
   for Link records targeting lists.

3. **"Owner = singular permanent controller" is the wrong framing.**
   Transferability + (optionally) moderator set are first-class. `attr_readonly
   :owner_id` was wrong. Even if no transfer endpoint in v1, schema should
   leave owner_id mutable.

4. **`:resource_owner` authorization symbol checks `created_by_id`**, not any
   generic ownership column. Won't match for models that use a different
   ownership column. Add a `:list_owner` lambda or alias the column.

5. **"Follow" smushes filter, signal, and audience-build** into one primitive.
   Worth splitting in design even if the UI gesture is unified.

6. **Soft-delete + slug-reuse-after-delete** works correctly with `conditions:
   -> { where(deleted_at: nil) }` on the uniqueness validation + a partial
   unique index on the table. Pattern worth keeping (used for `is_primary`
   uniqueness in v2 even though slugs are gone).

7. **Existence-hiding via `set_list` filtering by `visible_to?`** is a clean
   security pattern. Private resources collapse 403 → 404 by returning nil
   from set_list when not visible. Keep.

## Schema choices worth bringing forward

1. UUID primary keys, tenant_id + collective_id with default_scope (auto-scoped
   via ApplicationRecord).
2. `scope_matches_list` validation on join tables — catches the bug where a
   join row's `tenant_id`/`collective_id` drifts from the parent's (stale
   thread context).
3. `added_by_id` on `user_list_members` — load-bearing audit field once
   non-owners can add members.
4. Block symmetry on add/subscribe operations via `UserBlock.between?` —
   works correctly.
5. Counter caches via after_create_commit / after_destroy_commit callbacks
   that do `UserList.where(id: list_id).update_all(...)` — works correctly
   under dependent: :destroy cascades (the parent UPDATE is a safe no-op when
   the parent is mid-destroy).

## Things to redo differently

- Drop `UserListSubscriber` entirely.
- `owner_id` mutable (no `attr_readonly`), even if no transfer endpoint in v1.
- Don't `include Linkable` until concrete consumer exists.
- Add `creator_id` (immutable, audit) alongside `owner_id` (mutable, current
  controller).
- Drop slugs entirely. Use `truncated_id` (HasTruncatedId) like Note /
  Decision / Commitment.
- Lists are top-level at `/lists/:list_id`, NOT nested under user. A listing
  view at `/u/:handle/lists` shows lists owned by a user.
- "Add to list" gesture lives on `/u/:handle/actions/add_to_list` —
  auto-resolves current_user's primary list.

## Sequence that worked

- Phase 0 (schema + models, TDD) was smooth — well-bounded.
- Controller layer ran into the test-fixture gotchas (handle collisions,
  main_collective vs global_collective). Worth front-loading "main collective"
  setup into a test helper if it'll be reused.
- MCP smoke test was the most efficient way to catch
  frontmatter/capability/route-shape issues. Use it as soon as schema is
  stable.

---

## Phase 0 / Phase 1 design negotiations worth preserving

These were extended back-and-forth design decisions where the chosen
direction would not be obvious to a future reader looking at the shipped
state alone. Recording the alternatives considered and the rationale for
the final choice.

### Primary list is per-tenant, not per-collective

**Alternatives weighed:**
- **Per-(owner, collective) primary** (initial draft): consistent with the
  rest of Harmonic's collective-scoping; supports per-collective curation
  ("design folks" vs "finance folks" as distinct primaries); but forces a
  user in 5 collectives to manage 5 primary lists, makes "add to list"
  context-dependent, and creates awkward workspace cases.
- **Per-(owner, tenant) primary, lists still collective-scoped** (chosen):
  one primary per user per tenant, lives in `tenant.main_collective` by
  convention. Custom (non-primary) lists can still be collective-scoped.
  Simpler mental model ("I have one list"), context-independent gesture,
  no workspace special case.
- **Tenant-scoped lists with no collective** (rejected): too big a
  departure from collective-scoping; conflicts with the future
  addressable-subgroup use case.

**Why the chosen direction:** Twitter users don't think "follow Bob in this
context"; they think "follow Bob." The "I have one list" mental model wins
for the headline UX. Custom lists remain collective-scoped to support
"ping the design folks" later. Schema change was small: partial unique
index on `(tenant_id, owner_id) WHERE is_primary AND deleted_at IS NULL`.

### "Your list" framing (not "your primary list")

User-facing language is **"your list"** singular, not "your primary list."
The mental model is: every user has exactly one list strictly theirs (the
primary), plus optional additional lists they create that can be
transferred to other users or co-edited.

`primary` is internal terminology only — it appears in the `is_primary`
column, the `primary_user_list_in!` helper, the partial-index name.
User-visible strings (action descriptions, error messages) say "your list."

Three data-integrity invariants enforce the framing:
- A primary list's `owner_id` is immutable (cannot be transferred).
- A primary list's `is_primary` cannot be cleared (cannot be demoted).
- A non-primary list's `is_primary` cannot be set to true (cannot be
  promoted into the primary slot).

So `is_primary` is fixed at the moment of creation in both directions.
Non-primary lists CAN have their `owner_id` changed (transferable);
primaries cannot. The primary list is born primary and stays that way for
the life of the record.
