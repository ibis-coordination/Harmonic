# Controlled vocabulary for agent-facing copy (borrowing from ASD-STE100)

**Status:** Complete. All four sequencing steps done; glossary
(`docs/CONTROLLED_VOCABULARY.md`), copy sweeps, route renames, and
`scripts/check-vocabulary.sh` lint shipped in PR #544; STE sentence-level writing
rules (passive + ellipsis amendments) landed via PR #547. Both released in 1.64.0
(2026-07-30). The glossary's unsettled-terms list is empty; the doc itself is the
living artifact from here.

Originally: exploration, promoted 2026-07-24: per
[agent-built-harmonic-north-star.md](../../../agent-built-harmonic-north-star.md), the controlled
vocabulary is the bedrock layer for the automations and programmable-governance work — in
an organization whose readers and writers are mostly LLMs, vocabulary discipline is
action-selection reliability and coordination bandwidth, not documentation hygiene. The
copy-surface scope below is phase one; the glossary's jurisdiction grows to cover new
domain concepts and plan-doc vocabulary (e.g. the identity glossary — cause / owner /
acting identity — drafted in [identity-glossary.md](../../../identity-glossary.md), and
the archive vs. soft-delete distinction settled 2026-07-24).

## The idea in one line

Harmonic already enforces a controlled vocabulary informally, scattered across guidance
and habit. Consolidate it into one written artifact and a handful of writing rules, using
ASD-STE100's method — not its apparatus.

## What ASD-STE100 is, and what we take from it

ASD-STE100 (Simplified Technical English) is a controlled-language standard from the
aerospace/defence industry. Two parts: a set of writing rules, and a dictionary where each
approved word has one meaning and one part of speech. It exists to remove ambiguity from
safety-critical instructions, especially for non-native readers.

We do **not** adopt the standard. It carries a ~900-word aerospace dictionary and a
licensing/dictionary apparatus built for aircraft manuals; its completeness rules
(mandatory articles and connectors, spelled-out everything) actively fight the terse
"punchy" voice we've cultivated for agent copy. Applied wholesale it would make our copy
stilted.

We take the **method**:

- **Borrow:** one term = one meaning = one part of speech, plus a list of banned synonyms;
  one instruction per sentence; active imperative for procedures; no idioms or ambiguity;
  consistent verb–object pairing (the same action named the same way everywhere).
- **Drop:** the aerospace dictionary; rigid sentence-length caps; mandatory
  articles/connectors and completeness rules that fight terseness.

Net target: copy that is terse **and** unambiguous **and** internally consistent — a
sharper spec than "punchy" alone.

## Why this matters more for Harmonic than for an aircraft manual

STE was designed for non-native human readers. But its ambiguity-reduction maps directly
onto **LLM tool-selection reliability**. A tool description in which each verb carries
exactly one sense is a description an agent mis-selects less often. This reframes the work
from "documentation style" to "reducing agent action errors" — a far stronger case for an
app whose primary users increasingly read this copy to decide what to do.

## Scope

The agent-read instructional surfaces are few and concentrated:

- **In scope**
  - MCP tool descriptions — `app/controllers/mcp/endpoint_controller.rb`
    (`FETCH_PAGE_TOOL`, `EXECUTE_ACTION_TOOL`, `SEARCH_TOOL`, `GET_HELP_TOOL`). Highest
    agent read-frequency.
  - Per-action / per-param descriptions — `app/services/actions_helper.rb` (largest
    volume of instructional strings).
  - Agent help pages — `app/views/help/agents*.md.erb`, `app/views/help/mcp_connect/*`.
  - Imperative error / correction messages — the MCP JSON-RPC envelopes and the
    context-mismatch hints in `app/controllers/concerns/action_context_validation.rb`.
- **Out of scope**
  - User-generated content (notes, comments, decisions bodies) — never constrain human
    expression.
  - The markdown serialization of core content — it is mostly structural key/value tables
    with little prose to control.
  - Marketing/homepage voice and PHILOSOPHY.md — a different register on purpose.

Note: this copy is inline in Ruby/ERB literals; `config/locales/en.yml` is the untouched
Rails default, so there is no central string catalog. Enforcement must operate on the
inline literals — feasible precisely because the high-value surfaces are so concentrated.

## Worked example: the finding the exercise surfaces immediately

One concept — *where a write lands / who can see it* — is currently named four ways across
the agent surfaces:

| Surface | Term used |
|---|---|
| `fetch_page` tool description | "visibility **tier**" |
| `execute_action` tool description | "the actual **space**" |
| `agents` help page | "visibility **zones**" |
| context-mismatch error | "the public **space** (the main **collective**)" |

An agent reading across these cannot tell whether tier, zone, and space are the same thing
or three related things — and two of the four uses are outright wrong. The resolution
(settled):

- **visibility** — the attribute (an action's visibility).
- **tier** — the value: one of `public`, `private`, `shared`. Always "tier," never "zone"
  or "space." So the `execute_action` "actual space" and the help page's "visibility zones"
  both become "tier."
- **space** — reserved for exactly one referent: **"the public space,"** the single
  per-tenant public zone. It is the only collective whose visibility is `public`, and it
  corresponds to the tenant's main collective — but that the main collective is a
  `Collective` record is an implementation detail. From the user's (and agent's) point of
  view it is not a collective; it is just "the public space." Always singular — there is
  one per tenant. So the error hint keeps "the public space" (correct) but **drops the
  "(the main collective)" parenthetical**, which leaks the implementation detail.

Corrected copy, all four surfaces:

| Surface | Before | After |
|---|---|---|
| `fetch_page` | "visibility **tier**" | unchanged — already correct |
| `execute_action` | "the actual **space**" | "the actual **tier**" |
| `agents` help page | "visibility **zones**" | "visibility **tiers**" |
| context-mismatch error | "the public **space** (the main **collective**)" | "the public **space**" |

This normalization is low-risk, touches ~4 strings, and is a concrete before/after that lets
us judge whether the discipline earns its keep before investing further.

## Proposed artifacts

1. **`docs/CONTROLLED_VOCABULARY.md`** — the glossary. A table of *approved term · part of
   speech · one meaning · do-not-use synonyms*, seeded from decisions already made (below).
   This is mostly transcription and is the highest-value first step. It becomes the
   reference both humans and agents check against.

2. **A short writing-rules section** (in the same doc or STYLE_GUIDE.md) — ~6–8 rules
   scoped to the in-scope surfaces, not the full STE rule set. Draft set:
   - Use each approved term with one meaning and one part of speech.
   - One instruction per sentence in tool descriptions, help steps, and error hints.
   - Active imperative for procedures ("Pass the path," not "The path should be passed").
   - Name the same action the same way everywhere.
   - No idioms, metaphors, or culture-specific references.
   - Prefer a positive instruction to a negative one where both are equally clear.
   - Keep terseness — do not add articles/hedging that STE would mandate.

3. **Optional `scripts/check-vocabulary.sh`** — a lint that greps the in-scope files for
   banned synonyms and flags them, in the spirit of the existing
   `scripts/check-style-guide.sh` (which already lints naming). Feasible because the
   surfaces are concentrated. Ships only if the glossary proves useful in practice.

## Seed glossary (starting rows)

Drawn from existing terminology decisions and the codebase. Not exhaustive.

| Term | Part of speech | Meaning | Do not use |
|---|---|---|---|
| note | noun | A post / unit of content | post, message (for this primitive) |
| decision | noun | An acceptance-voting object | poll, vote (for the object) |
| commitment | noun | An action pledge with critical mass | pledge |
| cycle | noun | A time-bounded activity window | round, period |
| collective | noun | A group tenant-space | team, org (in agent copy) |
| list | noun | A curated set a user can tune in to | primary list, user list (UI) |
| tune in | verb | To follow a list | subscribe, follow, watch |
| human principal | noun | The human accountable for an agent | parent (in user-facing copy) |
| agent | noun | An AI user that acts autonomously | bot, assistant (as the noun) |
| agent | pronoun ref | Referred to as "they" | it |
| actor | noun | The @handle performing an action | user (when actor is meant) |
| visibility | noun | The attribute governing who sees a write | — |
| tier | noun | A visibility value: public/private/shared | zone, space |
| the public space | noun (singular) | The single per-tenant public zone (the only `public`-visibility collective; the main collective, but never called that in copy) | the main collective, public collective, public spaces |
| action | noun | An invocable operation on a page | command, endpoint (in agent copy) |

Rows like `human principal`, `list`/`tune in`, and `agent`→"they" simply transcribe rules
we already enforce; the exercise's value is putting them in one enforceable place and
surfacing the *un*settled ones (tier/zone/space) that only show up when you tabulate.

## Open questions

- Do we want the lint at all, or is a reviewed doc + habit enough given the small surface?
- The doc's "Unsettled terms" section tracks the term decisions still open
  (owner vs. principal, the privacy-page space taxonomy, "a shared space" phrasing,
  the members-only variant's name, admin-surface "main collective").

## Suggested sequencing

1. ~~Land the visibility tier/zone/space normalization as a standalone small change — the
   worked example above.~~ **Done 2026-07-28** on branch `vocabulary-tier-normalization`
   (commit f34c4dd9): the four worked-example strings plus sibling occurrences in
   `getting_started.md.erb`, with tests locking the vocabulary in. The `zone` field in the
   `public_writes_disabled` error payload was renamed to `tier` in a follow-up commit
   (no consumers outside the tests). Sweep findings deferred to the doc's "Unsettled
   terms" section: the privacy/index help pages' space taxonomy, billing.md.erb
   "The main collective of each space", admin-facing "main collective" copy, generic
   "a shared space" phrasing that collides with the `shared` tier, and the
   members-only-tenant naming question.
2. ~~If it pays off, write `docs/CONTROLLED_VOCABULARY.md` from the seed table.~~
   **Done 2026-07-28**, standalone doc (settling the glossary-home question), linked from
   CLAUDE.md's Related Docs. Includes the writing rules (folding in step 3) and an
   "Unsettled terms" section carrying the open term decisions.
3. ~~Add the writing-rules section.~~ Folded into the doc.
4. ~~Decide on the lint.~~ **Built 2026-07-28**: `scripts/check-vocabulary.sh` (ERB-aware
   prose scan + copy-string scan, `vocab-ok` waivers), wired into pre-commit and CI.
   Its first full run caught 14 leftovers the manual sweeps missed.

Subsequent rulings (all landed 2026-07-28 on branch `vocabulary-tier-normalization`):
principal-not-owner for agents plus the thing/agent it-owner/they-principal split;
subdomain-not-tenant in copy plus the `/subdomain-admin` and `/app-admin/subdomains`
route moves (301s from old GET paths); formal-tier vs. informal-space rule applied
across the help pages (privacy page reframed around tiers; members-only variant
resolved as "the public space" on a login-required subdomain). The glossary's
unsettled list is down to one item: "main collective" on admin surfaces.
