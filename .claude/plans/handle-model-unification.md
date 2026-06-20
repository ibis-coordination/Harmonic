# Handle model unification

Two related changes to do together, since they both touch how handles are stored, validated, and looked up.

## Goal 1: GitHub-style case-preserving handles

Today's model: handles are parameterized (lowercased + slugified) on save. Display form == lookup form. A user who registers "Linus" has it stored as "linus" — there is no remembered display case.

Target model: case-preserved display, case-insensitive lookup.

- A user who registers "Linus" keeps "Linus" as the display form.
- `@linus`, `@LINUS`, `@Linus` all resolve to the same identity.
- `Linus` cannot be registered if `linus` already exists.
- URL routing (`/u/Linus`, `/u/linus`) resolves consistently.

The display-flexibility upside is real: profiles, mentions, and audit lines can show the case the user actually chose, rather than a normalized slug.

## Goal 2: Unify user and collective handle namespaces

Today there are two namespaces:

- **User handles** — owned by `TenantUser`. Per-tenant. Normalized by `normalizes :handle`.
- **Collective handles** — owned by `Collective`. Per-tenant. Validated to lowercase form, not normalized.

A collective has a separate `identity_user` (a `TenantUser` with `user_type: "collective_identity"`) created at construction time with a **random** handle. So the collective `foo-team` has an identity user `@a1b2c3...` — two completely different handles for what users think of as the same entity.

Target: the collective and its identity user share one handle.

- A collective named `foo-team` has an identity user reachable at `@foo-team`.
- Mentions of `@foo-team` and links to `/collectives/foo-team` resolve to the same handle namespace.
- Collective and user handles share the same uniqueness constraint within a tenant.

This collapses two parallel concept hierarchies into one and removes a category of "why does this collective have a different handle than its identity?" confusion.

## Why together

Both goals require touching:
- The handle uniqueness constraint
- Lookup and normalization at every callsite
- The validation rules for what's an acceptable handle
- The `:handle` route param semantics

Doing them separately means doing this same migration twice. The case-preservation work is the right time to also flatten the namespace.

## Out of scope for this doc

Implementation strategy, migration sequencing, and breaking-change posture are deferred. This doc is just the destination.
