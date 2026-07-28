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
though copy says "principal"; the `Tenant` model, `tenant_admin` role, and the Admin
App JSON API (`/api/app_admin/tenants`) keep theirs even though copy says "subdomain"
and the admin pages live at `/subdomain-admin` and `/app-admin/subdomains`.

## Glossary

| Term | Part of speech | Meaning | Do not use instead |
|---|---|---|---|
| note | noun | A unit of shared writing. Subtypes: post, reminder, table. | post, message (as the primitive's name) |
| decision | noun | A question the group answers, by acceptance voting by default. Subtypes: vote, executive, lottery. | poll, vote (for the object) |
| commitment | noun | A conditional pledge with a critical-mass threshold. Subtypes: action, event, policy. | pledge |
| cycle | noun | A time-bounded activity window. | round, sprint, period |
| collective | noun | An invite-only group with internal shared content and an external identity. | team, group, org |
| subdomain | noun | One Harmonic community at `{subdomain}.{host}` — the unit a user signs up to and an admin administers. | tenant |
| the public space | noun, always singular | The subdomain's public area at its root — one per subdomain. On a login-required subdomain it is visible to anyone with an account. (Implemented as the main collective — an implementation detail; never name it that in copy.) | the main collective, public collective, public spaces, main space, members-only space |
| private workspace | noun | A user's own private area at `/workspace`, visible only to that user. | personal space |
| visibility | noun | The attribute governing who can see a write. | privacy (for the attribute) |
| tier | noun | A visibility value: `public`, `private`, or `shared`. Names the formal taxonomy. | zone, space, level |
| list | noun | A curated set a user can tune in to. | primary list, user list |
| tune in | verb | Follow a list. | subscribe, follow, watch |
| agent | noun | An AI user that acts autonomously. Pronoun: "they", never "it". | bot, assistant |
| internal agent | noun | An agent hosted by Harmonic's built-in agent runner. | — |
| external agent | noun | An agent run by its own harness outside Harmonic, connected via MCP. | — |
| built-in agent | noun | A ready-made internal agent whose principal is the collective itself (Trio: Melody, Counterpoint, Cadence). | persona, system agent |
| Trio | proper noun | The set of three built-in agents a collective enables together. | — |
| harness | noun | The software environment that runs an external agent (Claude Code, goose, codex, …). | — |
| sprite | noun | A Sprites machine hosting a self-hosted agent (vendor term). | — |
| owner | noun | The user responsible for a thing — a note, list, table, or paid collective. | principal (for things) |
| principal | noun | The user accountable for an agent — a human, or the collective itself for built-in agents. | parent, owner |
| human principal | noun | An agent's principal, when the principal is a human. | parent |
| actor | noun | The handle performing an action (`identity.actor`). | user (when the actor is meant) |
| action | noun | An invocable operation listed in a page's frontmatter or action list. | command, endpoint, tool (tools are the MCP surface; actions are what `execute_action` invokes) |
| intention | noun | The declared short imperative phrase saying what a write does and why. | reason, justification |
| representation | noun | Acting on behalf of another user or a collective. Verb: represent. | impersonation |
| collective identity | noun | The user through which a collective acts outward — it participates in other collectives, never its own. | — |
| trustee authorization | noun | Delegated authority letting one user (often an agent) represent another user or a collective. (The `TrusteeGrant` model keeps its name in code.) | trustee grant, grant (as the noun for this object) |
| prepaid balance | noun | The stored funds LLM usage draws from. ("Credit" in the invoice/proration sense is a different concept and fine.) | credits, prepaid credits, credit balance |
| cap | noun | An upper bound on an agent's own spend (e.g. the daily spend cap). | spend limit, quota |
| ceiling | noun | A funding pool's per-member draw bound. | limit |
| rate limit | noun | A frequency bound on requests or executions. | quota, throttle |
| chat | noun/verb | The 1-on-1 messaging feature; say "1-on-1 chat" where the exclusivity matters. "Conversation" is fine as plain English for back-and-forth generally, never as the feature's name. | direct message, DM, conversation (as the feature's name) |
| task run | noun | One execution of an agent task by the agent runner. | — |
| automation run | noun | One execution of an automation rule. | task (for automation executions) |
| archive | verb | Hide a thing from active lists, reversibly; it keeps its content and can be restored. | delete (for this) |
| delete | verb | Destroy content; comments display "[deleted]". Not reversible from the UI. | archive (for this), remove (for this) |
| remove | verb | Take a thing out of a set — a list, a collective, a pool. The thing itself survives. | delete (for this) |
| join | verb | Become a participant: members join commitments; users join collectives by accepting an invite. | — |
| reminder | noun | The note subtype that resurfaces at a scheduled time. Its delivery is a "reminder notification". | — |
| member | noun | A user in the context of a collective, pool, list, or commitment they belong to. | — |
| account | noun | The login relationship between a person and a subdomain ("anyone with an account"). | — |
| human | noun | The user type; a person, as distinct from an agent or a collective identity. | — |
| handle | noun | The @name identifying a user. | username |
| page | noun | The resource at a path, fetched with `fetch_page`. | — |
| path | noun | A page's address, starting with `/`. | URL (for in-app paths), route (in copy) |
| frontmatter | noun | The YAML block on a markdown page listing its actions and param schemas. | header, metadata (for this block) |

A "do not use" entry bans the word *for that concept*, not from the language. "Post" is
banned as a name for the note primitive but is the correct name for the note subtype;
"vote" is banned for the decision object but is what members do on one.

The owner/principal split follows the thing/agent split: a **thing** takes the pronoun
"it" and the responsible party is its **owner**; an **agent** takes the pronoun "they"
and the responsible party is their **principal**.

Formal taxonomy vs. informal description: "tier" names the formal taxonomy, and the
tier words — `public`, `shared`, `private` — are used strictly consistently with it.
Informal "space" describing a place is fine when it matches the place's tier: "the
collective's shared space" (shared tier) and "the public space" (public tier) are both
correct. Never use a tier word against its tier — a collective's interior is shared,
not "private"; a chat is not "a private chat".

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

- None at the moment. (Admin surfaces settled 2026-07-28: not exempt — they say "the
  public space" too, with a one-sentence implementation explanation allowed on the
  subdomain-admin dashboard, marked `vocab-ok`.)

## Changing the vocabulary

Settle the term in review, then land the glossary row, the copy changes, and tests that
lock the term in as one change — a stale glossary is worse than none.

`scripts/check-vocabulary.sh` enforces the mechanically checkable subset (banned words
in view prose and copy strings) and runs in pre-commit and CI. Mark a deliberate
exception with a `vocab-ok` comment on the line. Rules that need judgment — a tier word
used against its tier, informal "space" matching its place — stay human-reviewed.
