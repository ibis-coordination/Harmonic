# Controlled Vocabulary

The vocabulary and writing rules for Harmonic's instructional copy — the strings agents
and users read to decide what to do. Each approved term has one meaning and one part of
speech; each concept has one name. Most readers of this copy are LLMs choosing their next
action: a description in which every term carries exactly one sense is a description an
agent mis-selects less often. Vocabulary discipline here is action-selection reliability,
not documentation hygiene.

The method is borrowed from ASD-STE100 (Simplified Technical English): a small glossary of
approved terms with banned synonyms, plus a handful of writing rules. We do not adopt the
standard itself — its completeness rules fight the terse voice of our agent copy.

## Scope

These rules govern the instructional surfaces:

- MCP tool descriptions — `app/controllers/mcp/endpoint_controller.rb`
- Per-action and per-param descriptions — `app/services/actions_helper.rb`
- Help pages — `app/views/help/**`
- Error and correction messages — hints, denial payloads, validation responses
- User-facing UI copy generally, where these terms appear

They do not govern user-generated content, code identifiers, or the
marketing/PHILOSOPHY.md register. The `User#parent` association keeps its name even
though copy says "principal"; the `Tenant` model, `tenant_admin` role, and
`/tenant-admin` routes keep theirs even though copy says "subdomain".

## Glossary

| Term | Part of speech | Meaning | Do not use instead |
|---|---|---|---|
| note | noun | A unit of shared writing. Subtypes: post, reminder, table. | post, message (as the primitive's name) |
| decision | noun | A question the group answers, by acceptance voting by default. Subtypes: vote, executive, lottery. | poll, vote (for the object) |
| commitment | noun | A conditional pledge with a critical-mass threshold. Subtypes: action, event, policy. | pledge |
| cycle | noun | A time-bounded activity window. | round, sprint, period |
| collective | noun | An invite-only group with internal shared content and an external identity. | team, group, org |
| subdomain | noun | One Harmonic community at `{subdomain}.{host}` — the unit a user signs up to and an admin administers. | tenant |
| the public space | noun, always singular | The per-tenant public area at the tenant root. One per tenant. (Implemented as the main collective — an implementation detail; never name it that in copy.) | the main collective, public collective, public spaces, main space |
| private workspace | noun | A user's own private area at `/workspace`, visible only to that user. | personal space |
| visibility | noun | The attribute governing who can see a write. | privacy (for the attribute) |
| tier | noun | A visibility value: `public`, `private`, or `shared`. | zone, space, level |
| list | noun | A curated set a user can tune in to. | primary list, user list |
| tune in | verb | Follow a list. | subscribe, follow, watch |
| agent | noun | An AI user that acts autonomously. Pronoun: "they", never "it". | bot, assistant |
| principal | noun | The user accountable for an agent — a human, or the collective itself for built-in agents. | parent, owner |
| human principal | noun | An agent's principal, when the principal is a human. | parent |
| actor | noun | The handle performing an action (`identity.actor`). | user (when the actor is meant) |
| action | noun | An invocable operation listed in a page's frontmatter or action list. | command, endpoint, tool (tools are the MCP surface; actions are what `execute_action` invokes) |
| intention | noun | The declared short imperative phrase saying what a write does and why. | reason, justification |
| representation | noun | Acting on behalf of another user or a collective. Verb: represent. | impersonation |

A "do not use" entry bans the word *for that concept*, not from the language. "Post" is
banned as a name for the note primitive but is the correct name for the note subtype;
"vote" is banned for the decision object but is what members do on one.

## Writing rules

Scoped to the surfaces above. The target is copy that is terse, unambiguous, and
internally consistent.

1. Use each glossary term with its one meaning and one part of speech. Never use a
   banned synonym for a glossary concept.
2. One instruction per sentence in tool descriptions, help steps, and error hints.
3. Use the active imperative for procedures: "Pass the page path," not "The page path
   should be passed."
4. Name the same action the same way everywhere — the name in the error hint must match
   the name in the frontmatter and the help page.
5. No idioms, metaphors, or culture-specific references.
6. Prefer a positive instruction to a negative one when both are equally clear.
7. Keep terseness. Do not add articles, hedging, or exhaustive examples for
   completeness's sake.
8. When rejecting an action, name the expected value so the agent can self-correct.

## Unsettled terms

Known inconsistencies awaiting a decision. Do not propagate them into new copy; settle
them here first.

- **"owner" for resource ownership** — "principal" won for agent accountability
  (settled 2026-07-28), but lists, notes, tables, and paid collectives still have an
  "owner" in copy. Is that resource-ownership sense approved, or does it need its own
  term?
- **The space taxonomy on privacy/index help pages** — `/help/privacy` and the help index
  still use "space" generically ("Shared Spaces (Collectives)", "the main space", a
  "Space" table column), colliding with the reserved "the public space" and the `shared`
  tier.
- **"a shared space" as loose phrasing** — several pages describe Harmonic or a
  collective as "a shared space", colliding with the `shared` tier. Needs rephrasing or
  an explicit exemption.
- **The members-only variant** — on tenants whose main area requires login, copy says
  "Members-only space — the main space". What is this area's approved name?
- **"main collective" on admin surfaces** — tenant-admin pages and admin flash messages
  say "main collective". Decide whether operator-facing surfaces are exempt from the
  "the public space" rule.

## Changing the vocabulary

Settle the term in review, then land the glossary row, the copy changes, and tests that
lock the term in as one change — a stale glossary is worse than none.
