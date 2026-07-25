# Decision Voter & Proposer Eligibility

Status: implemented — all six phases, PR #534. Standalone slice carved out of
[decision-semantics-and-action-approval.md](decision-semantics-and-action-approval.md)
(gap #2, "no eligibility — anyone with access can vote; no declared
electorate").

**In scope:** two independently declared eligibility sets on a decision — who
may vote, who may propose options — each a union of clauses over one grammar,
settable at creation, editable while open, every change audited.

**Out of scope, and not blocked by this:** `DecisionResolution`, quorum,
threshold, electorate snapshots, `ProposedAction`, three-valued capability
grants. No persisted outcome, no verdict semantics; results stay advisory and
live-computed.

## What exists (verified)

- `decisions` has no settings jsonb ([structure.sql:743-765](../../db/structure.sql#L743-L765)).
- **Voting is already gated on collective membership** — the `vote` action's
  `authorization: :collective_member`
  ([actions_helper.rb:531-540](../../app/services/actions_helper.rb#L531-L540)),
  enforced for listings and execution by
  [ActionAuthorization](../../app/services/action_authorization.rb). So `open`
  and `members` resolve identically today.
- **All vote writes funnel through `DecisionActionService.cast_vote!`**
  ([decision_action_service.rb:75](../../app/services/decision_action_service.rb#L75)):
  three callers, all `ApiHelper` — `#vote` ([672](../../app/services/api_helper.rb#L672)),
  `#create_votes` ([723](../../app/services/api_helper.rb#L723)), and
  `#create_executive_selections!` ([1151](../../app/services/api_helper.rb#L1151)).
  `Api::V1::VotesController` is read-only; HTML `submit_votes` delegates to
  `#create_votes`.
- **All option adds funnel through `Decision#can_add_options?`**
  ([decision.rb:135-142](../../app/models/decision.rb#L135-L142)); update/delete
  variants delegate to it. Callers: [api_helper.rb:626](../../app/services/api_helper.rb#L626),
  [_options_section.html.erb:66](../../app/views/decisions/_options_section.html.erb#L66),
  three header labels in [decisions_controller.rb:97-110](../../app/controllers/decisions_controller.rb#L97-L110).
- **Settings changes are already audited.** `update_decision!`
  ([decision_action_service.rb:31-42](../../app/services/decision_action_service.rb#L31-L42))
  diffs `decision.changes` into a `decision_updated` entry.
- **Both authorization contexts already carry the decision** as `:resource` —
  execute-time [action_authorization_check.rb:127-136](../../app/controllers/concerns/action_authorization_check.rb#L127-L136),
  listing-side [markdown_helper.rb:178-192](../../app/helpers/markdown_helper.rb#L178-L192).
- **Roles** are a closed enum on `CollectiveMember` via
  [HasRoles](../../app/models/concerns/has_roles.rb): `admin`, `representative`,
  `summarizer`, `automator`, `moderator`.
- **Lists**: [UserList](../../app/models/user_list.rb) / `UserListMember`,
  supporting `visibility: "private"` + `add_policy: "owner_only"`.
  `UserListMember` validates `member_is_collective_member`, so a list can never
  widen the electorate past the collective. **`UserList` is not handled by
  `collective_export_service` or `collective_import_service` at all.**
- **Under representation `@current_user` is the represented user**
  ([representation_policy.rb:109-113](../../app/controllers/concerns/representation_policy.rb#L109-L113)),
  so a trustee voting for Alice produces a participant whose user is Alice.
- `options_open` has ~24 app-side references including export/import and
  `record_creation!` metadata, whose shape is pinned by
  `audit_chain_metadata_pii_test.rb`.

## Design

### Grammar

An eligibility rule is a **union of clauses**; a user is eligible if any clause
matches.

```json
{"any_of": [
  {"type": "users", "user_ids": ["<alice>", "<bob>"]},
  {"type": "role",  "role": "admin"},
  {"type": "list",  "list_id": "<uuid>"}
]}
```

| type | payload | matches |
|---|---|---|
| `members` | — | `collective.user_is_member?(user)`, or the collective's identity user |
| `role` | `role` | that user's `CollectiveMember#has_role?` |
| `list` | `list_id` | membership in that `UserList` |
| `users` | `user_ids` | user's id is in the array |

There is deliberately **no clause for "everyone"**. A NULL column means no
restriction. "Everyone" is a property of the call site, not a set of users, and
giving it a clause would put an unenumerable member into a grammar whose whole
purpose is describing bounded sets — it would also be the one construct that
cannot appear inside a search operator value, since a bare word there is a
full-text term.

**Union only — no `all_of`/`none_of`.** Every clause widens, so a rule always
renders as a plain sentence with no precedence to explain. Intersection and
negation extend the same storage later if a real need appears; what they mostly
buy is exclusions, better expressed by naming who *is* included.

### Storage

```
decisions
  voter_eligibility     jsonb   -- NULL = no restriction
  proposer_eligibility  jsonb
```

One column per set, not typed columns per clause field: payloads vary in shape,
the array is variable-length, and `decision.changes` diffs the column as a unit
so an audit entry reads as one coherent before/after value. GIN stays available
if "decisions I can vote on" ever needs an index.

Both columns are nullable with **no default**, so every existing row and every
unmodified create path behaves as today. Absence is the representation of "no
restriction" — there is no sentinel value standing in for it.

**Always assign a whole rule** (`decision.voter_eligibility = rule.to_h`).
In-place mutation of a jsonb attribute is not dirty-tracked, so it would skip
both the audit entry and the save.

### `UserSet` value object

A PORO (`app/models/user_set.rb`, not `ActiveRecord`) owns the grammar
so `Decision` stays thin and the logic is unit-testable without a database:
`parse(jsonb_or_compact_string, collective:)`, `matches?(user)`, `to_h`,
`to_s`, `validation_errors(collective:)`, `describe`.

`Decision#eligible_voter?(user)` / `#eligible_proposer?(user)` delegate, and
memoize per `user_id` on the instance, since the check sits inside loops:
`ApiHelper#create_votes` calls `cast_vote!` once per submitted vote against a
single memoized decision, and a `list` clause costs two queries each time. The
memo is dropped by the rule writers and by `reload` — the latter swaps
`@attributes` but leaves plain ivars alone.

### Resolution

- **Nil user is never eligible.** Decisions are anonymously readable on tenants
  in `ANON_READABLE_TENANT_SUBDOMAINS`, so both predicates take a nilable user
  and return false.
- **The electorate is named to everyone who can read the decision** — page,
  markdown, and `api_json` alike. An electorate you cannot see is one you cannot
  contest, and every clause type references data the reader can already see:
  public lists, roles shown in member listings, and named members whose ballots
  the voters page publishes anyway. Hiding the rule would also be futile, since
  a restricted decision reveals its electorate as it votes.
- **A dangling clause matches nobody; it does not void the rule.** A deleted
  `UserList` or a removed user leaves the other clauses working. Under union
  semantics this narrows rather than widens — the safe direction — and avoids
  locking out eligible voters over an unrelated broken reference. The decision
  page surfaces the broken clause to those who can edit settings.
- **A collective votes in OTHER collectives, through its identity user.** A
  collective faces outward through that identity while its own space is where
  its members deliberate, so it never votes on its own decisions. Under
  collective representation the session swaps `current_user` to the identity
  (`RepresentationSession#effective_user`), so the participant behind the vote
  is the collective and eligibility asks whether the COLLECTIVE is in the
  electorate, not the human at the keyboard. Naming a guest collective works
  because `Collective#create_identity_user!` joins the identity to the tenant's
  main collective, giving it a real `CollectiveMember` row; a `users:` clause
  naming a collective in its own collective is correctly refused.
- **Identity users mirror `ActionAuthorization`**: `collective.identity_user?(user)`
  satisfies `members`, so collective identities (and the automations acting as
  them) do not silently lose abilities they have everywhere else. A restrictive
  rule *does* block them, which is intended.
- **Evaluated live, never snapshotted.** Freezing the electorate at open is a
  quorum concern; with no quorum or threshold there is no denominator to
  stabilize and no verdict to pack.

### Validation

- `any_of` present, an array, 1..10 clauses. Empty means nobody can vote — a
  validation error, not a reachable config.
- Clause `type` in the table above, carrying exactly that type's keys.
- **`members` may only appear as the sole clause.** Every other clause selects a
  subset of collective members, so a union containing `members` collapses to it;
  anything beside it is dead weight that reads as if it restricted something.
- `role` in `CollectiveMember.valid_roles`.
- **`voter_eligibility` must be absent unless the subtype is `vote`.** Lotteries
  are drawn and executive decisions are settled by their decision maker, so a
  voter rule on either is inert; rejecting it beats accepting a restriction that
  silently does nothing. `proposer_eligibility` applies to every subtype — a
  lottery's entries are options.
- `list_id` resolves to a non-deleted, **public** `UserList` in this collective.
  A private list is owner-only, but a decision publishes its voters by name, so
  a private-list electorate would convert owner-only membership into
  collective-visible membership — and could not stay secret anyway, since it
  reveals itself as it votes. Refused on write, and refused again at match time
  in case a list is turned private after a rule already referenced it.
- `user_ids`: 1..200, deduped, each an existing user who is a collective member
  **at write time**. Membership is not re-checked on read — that is what a
  `members` clause is for.

### Compact grammar for markdown, MCP, and the API

Storage is UUID-based; the agent-facing surface takes and renders a compact
form that follows the **search filter grammar** — space-separated `key:value`
clauses, comma-separated values, and an optional `@` on handles, matching
search's deliberate `creator:@alice` / `creator:alice` equivalence. Keys are
singular with multiple values, as `creator:`/`voter:`/`participant:` already
are; the stored clause type stays `users` because there it names a JSON array.

```
voter_eligibility: user:alice,@bob role:admin list:abc123
```

Handles are input-only and resolve to UUIDs immediately, so a stored rule never
rots on rename. `to_s` renders back to this form for the markdown views.

An **absent** param means "no change", so a partial update that says nothing
about eligibility does not reset it. A **present-but-empty** param means "no
restriction": the settings form always submits both fields, so someone who
clears one to lift a restriction has to get what they asked for rather than a
successful redirect that changed nothing.

### Composition with `options_open`

`options_open` is untouched — the column, its export/import serialization, its
audit metadata. Proposer eligibility composes with it:

```ruby
def can_add_options?(participant)
  # ...existing guards (nil, closed, authenticated, MAX_OPTIONS)...
  return false unless eligible_proposer?(participant.user)
  options_open? || participant.user_id == created_by_id
end
```

`options_open` is the coarse switch (everyone / creator only), eligibility the
fine-grained restriction. The AND is additive, so a default-valued decision
behaves byte-for-byte as today. **The forms no longer offer an `options_open`
control at all** — "who can add options" is proposer eligibility now, and
creator-only is expressible as a `user:` clause naming the creator. Two controls
for one question is one too many, and dropping the dropdown is also what keeps
the form from producing the incoherent combination (`options_open: false` plus a
rule the creator does not match, which resolves to nobody). The column, its
export/import serialization, and its audit metadata are untouched, and API and
MCP can still set both independently; the AND rule is documented there.

### Enforcement

**Voting**

1. `cast_vote!` raises unless `!decision.is_vote? || decision.eligible_voter?(vote.decision_participant.user)`.
   Guard of last resort covering all three write paths. Two deliberate details:
   - Gated on `is_vote?`, exempting `create_executive_selections!`, which writes
     votes as the effective decision maker on an `executive` decision.
     Executive and lottery reject ordinary votes upstream.
   - Checks **the participant's user**, not `actor:`. Under representation those
     coincide, but a trustee must be judged against the represented user's
     eligibility, and the REST path can target a participant directly.
2. The `vote` action's `authorization:` becomes
   `ActionAuthorization.all_of(:collective_member, :eligible_voter)`. It must
   conjoin, never be an array of symbols — arrays are OR in that module, which
   would *widen* access, and `all_of` exists so that the conjunction has a name
   rather than being re-derived as an inline Proc per call site. The
   `eligible_voter` check stays permissive when `:resource` is absent or is not
   a `Decision`, per the listing convention. On routes
   where `current_resource` resolves to a `DecisionParticipant` rather than the
   decision, this layer no-ops and `cast_vote!` is the guard.
3. HTML: `submit_votes` early-returns with an alert, and the options partials
   render the ballot read-only for ineligible viewers.

**Proposing**

1. `can_add_options?` as above — covers the API helper, the options partial, and
   the controller header labels in one edit.
2. The `add_options` action gets the parallel
   `all_of(:collective_member, :eligible_proposer)`, same constraints.
3. HTML: `create_option_and_return_options_partial` refuses with a 403.

**The two HTML routes consult the declared rule themselves.**
`ActionAuthorizationCheck` gates only `POST /actions/<name>`, so a route whose
path carries no action name — `submit_votes`, `options.html` — is reached by
none of it. Leaving them to the service layer means enforcing whatever
`cast_vote!` and `can_add_options?` happen to raise on, which is narrower than
the declared rule (no capability, trustee-grant, or user-block check) and fires
only after side effects are written: an ineligible ballot post saved a receipt
preference and a `DecisionParticipant` first, and an ineligible option post
escaped as a bare `RuntimeError` carrying record ids. Both call
`ActionAuthorization.authorized?` for the action they implement, so the HTML and
`/actions/` paths run the same gate without either becoming the other's
special case.

### Audit

Once the two columns are assignable in `ApiHelper#update_decision_settings`,
`update_decision!` diffs them automatically — **but its transform is
`val&.to_s`, which renders a jsonb Hash as a Ruby inspect string rather than
JSON.** Patch the transform to JSON-encode Hash and Array values. This is safe:
no existing decision column holds a Hash, so no current audit entry or chain
hash changes.

`record_creation!`'s `initial_values` gains both rules, requiring an update to
`audit_chain_metadata_pii_test.rb`. Rules carry user and list UUIDs;
`decision_maker_id` already sets that precedent.

**A `list` clause delegates the electorate, and the decision's chain records
only the reference.** Editing the referenced list moves the electorate without
writing a `decision_updated` entry. Closing that would mean fanning an audit
entry out to every open decision referencing the list on every membership
change — not worth it. Documented instead, and it is the reason to prefer a
`users` clause for an ad-hoc vote and a `list` clause only for a durable,
reused electorate.

### Votes cast before a rule tightens

Retained, and they still count; only new and updated votes are blocked. The
chain records who changed the rule and when, so the history is reconstructible.
Correct while results are advisory; the first thing quorum and threshold must
revisit.

## Phases

Red-green TDD throughout. **Enforcement lands before the rules are settable
from the UI or API** — shipping a control that promises restriction and delivers
none is worse than shipping nothing. Phases 1–2 are prerequisites; 3 and 4 are
independent of each other.

1. **`UserSet` value object.** Parse (jsonb and compact grammar),
   `to_h`/`to_s`, validate, `matches?`, `describe`. No schema, no database.
   *Tests:* every clause type against member / non-member / identity user / nil
   user / dangling reference; two- and three-clause unions; every validation
   branch including empty `any_of`, over-cap, and `open` beside another clause;
   `parse(to_s)` round-trip; handle→UUID resolution.

2. **Schema and `Decision` integration.** Migration for the two jsonb columns
   with defaults; `eligible_voter?`, `eligible_proposer?`, memoization, model
   validations delegating to the value object. No enforcement yet.
   *Tests:* defaults leave existing decisions unchanged; invalid rules rejected
   at the model layer; memoization does not re-query per call.

3. **Voting enforcement.** The `cast_vote!` guard, the `vote` action Proc, the
   `submit_votes` early return, read-only ballot rendering. Rules set directly
   on the record in tests.
   *Tests:* ineligible member blocked on all three write paths; a member
   matching any one clause of a union passes; trustee voting for an ineligible
   represented user blocked, for an eligible one succeeds; executive selections
   unaffected; `vote` absent from the action listing for an ineligible user and
   403 on execute; default-valued decisions unchanged.

4. **Proposing enforcement.** `can_add_options?` conjunction, the `add_options`
   Proc, options-section rendering.
   *Tests:* ineligible member cannot add / update / delete options; the
   `options_open: false` creator bypass still works; lottery entries respect
   proposer eligibility; the `options_open` composition table.

5. **Write surfaces.** Params on `create_decision` and
   `update_decision_settings` in `ACTION_DEFINITIONS`, `ApiHelper`, and the
   `decision_params` permit list. Eligibility fields on `new.html.erb` and
   `settings.html.erb`, once per set. **Shipped as a text field taking the
   compact grammar, not the clause-builder chips originally planned** — a
   narrower control cannot represent a multi-clause union, so it would silently
   flatten any set built through the API the moment someone opened the form.
   The syntax lives behind a tooltip pointing at `/help/user-sets` rather than
   in an inline description. The `update_decision!` JSON-encoding patch;
   `record_creation!` metadata and the pinned PII test.
   *Tests:* set a union through the compact grammar and the HTML form; reject
   invalid clauses on both; the change appears in `decision_updated` metadata as
   JSON; `can_edit_settings?` still gates who may change it.

6. **Read surfaces and portability.** `api_json`, `show.md.erb`,
   `settings.md.erb`, `new.md.erb`, the decision page's summary via `describe`,
   and `collective_export_service` / `collective_import_service` /
   `user_data_export_service`.
   *Tests:* export → import remaps `users` clauses via the handle-keyed
   `@user_mapping`; a `list` clause is dropped to a dangling reference on import
   and the decision stays usable; markdown renders the compact grammar;
   `api_json` includes both rules.

## Invariants

- An absent set means no restriction, and reproduces today's behavior exactly on
  every surface.
- A user matching any clause is eligible; a nil user never is.
- Evaluated live; nothing is snapshotted.
- Every change to a rule is written to the decision audit chain, as JSON.
- A dangling clause matches nobody and never voids the rest of the rule.
- Eligibility never turns private data public: a rule may only reference lists
  that are already visible to the collective.
- A rule always has at least one clause.
- Voter eligibility is checked against the participant's user, never the acting
  trustee.
- Eligibility never *widens* access — the whole rule is a conjunction with the
  existing `:collective_member` authorization, never a replacement, and never
  expressed as an OR-array.
- Handles are input-only; rules store UUIDs.
- The two rule sets are independent; neither implies the other.

## Open questions

- **`list` clauses do not survive collective export/import** — `UserList` is not
  exported, so the clause dangles and matches nobody in the target collective.
  Acceptable under per-clause fail-closed, but if lists become portable this
  should be revisited together.
- **Notifications.** A restricted decision still notifies the whole collective.
  Whether ineligible members should be notified at all is a product question
  this slice does not answer.
- **Retained votes from a since-ineligible voter.** Counted here because
  results are advisory. Once thresholds exist, "counted but ineligible" is a
  correctness question, likely resolved by excluding them from the tally at
  close rather than deleting them.
- **Should `members` admit a collective's own identity in its own collective?**
  The clause mirrors `ActionAuthorization`'s `:collective_member`, which treats
  `identity_user?` as membership so automations can act in their own collective.
  But a collective is not a member of itself, so for *voting* this may be the
  wrong inheritance. Only reachable when something acts as the identity inside
  its own collective; left as-is rather than diverging from the authorization
  check without a concrete case.
- **Should the creator always retain proposer eligibility?** A creator who
  restricts proposing to a rule they do not match locks themselves out of adding
  options (they can still edit settings). The UI makes this hard to reach by
  accident; the API allows it.
- **`role` clauses are limited to the closed `valid_roles` enum**, so they suit
  governance-shaped decisions and not ad-hoc working groups. Union makes this
  much less limiting — a `role` clause combines with `users` — so no change is
  proposed.
