# Capability Roles: `automator` and `moderator`

Status: planning. Component 1 of [harmonic-personas-overview.md](harmonic-personas-overview.md);
fully independent — no persona or moderation work required.

## Scope

Add two collective-member roles alongside the existing `admin` / `representative`
/ `summarizer`:

- **`automator`** — grants the ability to create and configure the collective's
  automations, which today requires `admin`.
- **`moderator`** — a named role that grants NO special capabilities yet. The
  moderation controls it will eventually gate are a separate track
  ([moderation-controls-exploration.md](../../../moderation-controls-exploration.md)).
  Naming it now lets it be granted, displayed, and mentioned before the
  capabilities exist.

Both are ordinary grantable roles: any member — human or agent — can hold them,
assigned by admins through the existing role-grant flow. Personas will be
*default* holders later, never exclusive holders.

## What exists (verified)

- Roles live in `CollectiveMember.settings["roles"]` via the `HasRoles` concern
  ([has_roles.rb](app/models/concerns/has_roles.rb)); `valid_roles` is the
  hardcoded list `["admin", "representative", "summarizer"]`.
- Role grant/revoke: `CollectivesController#assign_role` (admin-only; guards
  against demoting the creator / last admin — admin-specific, no change needed).
- Group tags derive automatically: `ReservedHandles.role_tags` pluralizes
  `valid_roles`, so `@automators` and `@moderators` become reserved, resolving
  mention tags with zero mention-code changes (#453 mechanism).
- Automation management gate: `require_collective_admin` in
  [collective_automations_controller.rb:473](app/controllers/collective_automations_controller.rb#L473)
  — the single choke point for collective automations CRUD.
- Automations are also paid-gated (`Collective::PAID_FEATURE_ERROR` gates on
  tier). That gate is orthogonal and unchanged: `automator` relaxes WHO may
  manage automations, not WHETHER the collective has them.

## Changes

1. `HasRoles.valid_roles` → `["admin", "representative", "summarizer", "automator", "moderator"]`.
   (`HasRoles` is shared with TenantUser; confirm tenant-level role surfaces
   don't render unexpected options.)
2. `require_collective_admin` in the automations controller → admin OR
   `automator` (rename to `require_automation_manager` or similar). Audit for
   any other automation-management gates (markdown actions, API) and align.
3. Convenience predicates if the codebase pattern calls for them
   (`is_automator?`, `is_moderator?` alongside `is_summarizer?`).
4. Role-management UI (member settings/roles picker) picks the new roles up from
   `valid_roles` — verify nothing hardcodes the role list.
5. Docs/help: role list mentions in help pages; note `@automators`/`@moderators`
   tags appear automatically.

## Decisions

- **Made**: roles independent of personas, grantable to anyone; moderator
  capability-less for now; **automator manages ALL of the collective's
  automations** — the role relaxes WHO passes the existing admin gate, no
  per-owner scoping.
- Role grants already emit `collective_member.role_granted` events; nothing new
  needed. Help copy must say explicitly that `moderator` grants nothing yet.

## Tests (red-green)

- `has_roles` / collective_member: new roles valid, grantable, revocable;
  `users_with_role` resolves them.
- Mention parsing: `@automators` / `@moderators` resolve to holders
  (should pass via derivation — pin it).
- Automations controller: automator (non-admin) can create/edit/enable/disable;
  plain member still refused; paid-tier gate still applies to automators.
- Role grant endpoint: admins can grant/revoke both roles to a human and to an
  agent member.

## Size

Small. One PR.
