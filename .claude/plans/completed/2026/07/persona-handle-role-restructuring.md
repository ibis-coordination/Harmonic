# Persona Handle & Mention-Role Restructuring

Status: PR #508 open, branch `persona-handle-role-restructuring` (6 commits,
2026-07-16 — the 6th memoizes persona_user per instance with activator
invalidation). The persona namespace (`trio`, `trio-*`) is reserved
UNCONDITIONALLY — users and collectives alike (which reverses #449's
agent-names-claimable-as-collective-handles stance; identity users mirror
collective handles, so both namespaces are barred together). Decided by Dan;
no exceptions, no special-case logic. Component 2 of [harmonic-personas-overview.md](harmonic-personas-overview.md).
Valuable for trio alone; establishes the identity scheme melody/counterpoint reuse.
Builds on PR #504 (trio principaled by collective identity).

## Goal

Cut the special-case mapping that links every collective's trio to the public
`/u/trio` profile. After this:

- Every trio's handle follows **`trio-[collective_handle]`** — unique per tenant
  (collective handles are), intuitive, and each trio links to its OWN profile.
- **`@trio` still resolves to the current collective's trio**, but via a
  reserved **persona role** on its CollectiveMember row, not via the
  `collective.trio_user` special case.
- No user holds the literal handle `trio`; `/u/trio` no longer resolves.

## What exists (verified)

Three special cases to remove/replace:

1. [TrioSeeder#pick_handle](app/services/trio_seeder.rb) — main collective's trio
   claims literal `trio`; others get `trio-<hex4>`.
2. [User#handle](app/models/user.rb#L556) override — every trio *reports* handle
   "trio" regardless of its stored TenantUser handle; this is what makes all
   trio mentions/profile links render as `@trio` → `/u/trio`.
3. [MentionParser](app/services/mention_parser.rb#L133) — `@trio` special-cased
   to `collective.trio_user` in `resolve_collective_local` AND `resolve_paths`.

Supporting facts:
- `ReservedHandles::AGENT_ROLES` (`{"trio" => "trio"}`) already gates who may
  claim the literal handle and marks it collective-local. It stays as the
  registry, remapped: mention tag → persona role.
- Role tags resolve via `collective.users_with_role(role)` →
  `collective_members.where_has_role` — note it does NOT filter archived
  members.
- `sync_identity_user_handle!` (after_update on Collective) is the precedent for
  keeping a dependent user's handle in sync with the collective's.
- Main collectives have random hex handles (`SecureRandom.hex(16)`), so the main
  collective's trio becomes `trio-<32hex>`. Accepted consequence of "no special
  cases" (revisits automatically if main collectives ever get real handles).

## Design

### Persona roles (new concept)

- A reserved CollectiveMember role per persona; this component introduces `trio`.
- **Activator-managed only**: `TrioActivator` adds the role on activate/restore
  and removes it on deactivate; the role-grant endpoints refuse persona roles.
  Removing on deactivate (rather than relying on member archival) keeps the role
  the single truthful signal and sidesteps `where_has_role`'s lack of an
  archived filter.
- Persona roles are NOT in the pluralize-derived group-tag set the way
  capability roles are — the singular tag comes from `AGENT_ROLES`
  (`@trio` → members with role `trio`). Decide whether `valid_roles` includes
  them (validation needs them valid) while the grant endpoint excludes them —
  likely: `valid_roles` = capability roles + persona roles, with a separate
  `PERSONA_ROLES` list the endpoints and pickers exclude.

### Handles

- `TrioSeeder#pick_handle` → `"trio-#{collective.handle}"`, no main special case.
- Delete the `User#handle` trio override (trio reports its stored handle);
  delete whatever makes `/u/trio` context-aware in UsersController.
- **Reserve the persona prefixes**: no non-system user may claim a handle
  matching `trio-*` (and later `melody-*` / `counterpoint-*`) — squatting is
  both a uniqueness collision (activation would hit the tenant_users unique
  index) and an impersonation vector. Lives in `ReservedHandles` + the
  TenantUser handle validation.
- **Rename sync**: collective handle changes update the trio's handle, alongside
  `sync_identity_user_handle!`.

### Mention resolution

- `MentionParser.resolve_collective_local`: the trio branch becomes generic —
  for each `AGENT_ROLES` tag wanted, `collective.users_with_role(persona_role)`.
- `resolve_paths`: same replacement; each trio links to its own real path.
- `MentionParser::TRIO_HANDLE` alias and `User` references keep working
  (the tag itself is unchanged — only the mechanism moves).

## Migration

1. Rename existing trio TenantUser handles to `trio-[collective_handle]`
   (collective found via CollectiveMember join, as in the principal backfill).
   Guard: skip + warn on collision with an existing handle (squatters);
   orphan trios (no standard collective) keep their hex handles.
2. Add the `trio` persona role to every ACTIVE trio's CollectiveMember row
   (active = `collective.trio_user_id` set); deactivated trios get it on
   next restore via the activator.
3. Old stored text mentioning hex handles (`@trio-a1b2c3d4`) goes dead-text;
   `@trio` mentions re-resolve on render and keep working. Accepted.

### Structural generalization (decided: full, now)

The persona role is not just mention state — it becomes the **single source of
truth** for "who is this collective's trio", and `collective.trio_user_id` is
dropped in this component (so component 3 adds entries, not mechanisms).

- New lookup: `Collective#persona_user(persona_role)` — the active member
  holding the persona role (via `where_has_role`; activator add/remove keeps it
  activation-aware, preserving today's trio_user_id semantics exactly: present
  while active, absent while deactivated).
- Touchpoints to convert (verified by grep): `belongs_to :trio_user` +
  `downgrade!`'s `trio_user_id.present?` + `ensure_trio_funded!` in
  collective.rb; TrioSeeder (`update!(trio_user: trio)` goes away — activator
  role-add replaces it); TrioActivator (reconcile!'s actual-state check,
  restore!/deactivate! link writes, find_existing_trio); MentionParser (being
  replaced by role resolution anyway); the detach guards in
  collectives_controller (`trio_user_id` comparison); users_controller
  (workspace-trio flash), autocomplete_controller, notification_dispatcher,
  users/settings view.
- Migration: backfill the `trio` persona role onto every active trio's
  CollectiveMember row (active = `trio_user_id` currently set), then drop the
  `trio_user_id` column. Deactivated trios get the role on next restore via
  `find_existing_trio` (which switches to the membership+system_role join it
  already half-uses).
- `TrioActivator.reconcile!` desired-vs-actual: actual becomes
  `persona_user("trio").present?`.

## Out of scope

- melody/counterpoint (component 3 introduces their entries in `AGENT_ROLES`,
  seeders, prefixes — the mechanisms here are built to take them).

## Tests (red-green)

- Seeder: handle pattern for main and non-main collectives; collision behavior.
- Activator: role added on activate/restore, removed on deactivate;
  reconcile! drives off the role; `persona_user("trio")` present/absent tracks
  activation.
- Pool: ensure_trio_funded! and the detach guards work off `persona_user`.
- MentionParser: `@trio` resolves to role-holder; nothing resolves when trio
  deactivated; paths point at the trio's own profile; cross-collective isolation
  (collective A's `@trio` never resolves to collective B's trio).
- ReservedHandles/TenantUser: prefix reservation — non-system user refused
  `trio-anything`; system trio allowed.
- Rename sync: collective handle change renames trio's handle.
- Migration covered by a data check in dev + the seeder/activator tests.

## Size

Medium-large (the structural generalization roughly doubled it, deliberately —
it buys component 3 its smallness). One PR.
