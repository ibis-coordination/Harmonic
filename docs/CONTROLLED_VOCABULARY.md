# Controlled Vocabulary

The vocabulary and writing rules for Harmonic's instructional copy — the strings agents
and users read to decide what to do. Each approved term has one meaning and one part of
speech; each concept has one name. Most readers of this copy are LLMs choosing their next
action: a description in which every term carries exactly one sense is a description an
agent mis-selects less often. Vocabulary discipline here is action-selection reliability,
not documentation hygiene.

The method is borrowed from ASD-STE100 (Simplified Technical English): a small glossary of
approved terms with banned synonyms, plus a handful of writing rules. We do not adopt the
standard itself — its completeness rules fight the terse voice of our agent copy. (STE's
"terminology allowance" — each organization defines its own dictionary of approved
technical terms beyond the base vocabulary — is exactly what the glossary below is.)

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
| type | noun | The primitive kind of an item: note, decision, or commitment (the search `type:` operator). | kind |
| subtype | noun | The structural variant within a type: post/reminder/table, vote/executive/lottery, action/event/policy. | — |
| comment | noun | A note attached to other content; it appears beneath it and links back. | reply (as the object's name) |
| author | noun | The writer of a written note (post, reminder) or a comment — the one whose words they are. Tables are data, often collaboratively built — a table note has an owner, not an author. | — |
| creator | noun | The user who created a resource initially — usually also its owner. (Also the search `creator:` operator, which covers all types.) | — |
| option | noun | A proposed answer on a decision. On lotteries, options are called entries. | choice |
| acceptance voting | noun | The default decision mechanism: accept or reject each option, then prefer among accepted. | approval voting (as its name) |
| decision maker | noun | The user who selects options and closes an executive decision. | — |
| final statement | noun | The creator's closing explanation on a decision. | — |
| audit chain | noun | The tamper-evident, hash-linked event log on every decision. | — |
| audit receipt | noun | The hash of a vote's audit-chain entry, returned to the voter. | — |
| critical mass | noun | The participation threshold that activates a commitment. | quorum, threshold (as its name) |
| cycle | noun | A time-bounded activity window. | round, sprint, period |
| tempo | noun | A collective's cycle length: daily, weekly, or monthly. | cadence, frequency |
| heartbeat | noun | A per-cycle presence signal; sending one is how a member shows up for the cycle. | check-in |
| link | noun | An automatic bidirectional reference created when one item's body references another's URL. The reverse side is a backlink. | — |
| mention | noun/verb | An @handle reference that notifies its target. Role tags (`@admins`, …) and `@everyone` are group mentions. | tag (for this) |
| read confirmation | noun | The record that a member confirmed reading a note (the `confirm_read` action). | like, reaction |
| notification | noun | A delivery telling a user about activity involving them. States: unread, read, dismissed. | alert |
| feed | noun | A page whose content is a search with fixed filters. | timeline, stream |
| user set | noun | A composition-based description of a group of users, written as clauses (`user:`, `role:`, `list:`, `members`). | — |
| mutuals | noun | Two users who have tuned in to each other. | friends, followers |
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
| owner | noun | The user responsible for a resource — a table note, list, private workspace, or paid collective. Usually the creator, though ownership could in principle be transferred. | principal (for things) |
| principal | noun | The user accountable for an agent — a human, or the collective itself for built-in agents. | parent, owner |
| human principal | noun | An agent's principal, when the principal is a human. | parent |
| actor | noun | The handle performing an action (`identity.actor`). | user (when the actor is meant) |
| action | noun | An invocable operation listed in a page's frontmatter or action list. | command, endpoint, tool (tools are the MCP surface; actions are what `execute_action` invokes) |
| intention | noun | The declared short imperative phrase saying what a write does and why. | reason, justification |
| representation | noun | Acting on behalf of another user or a collective. Verb: represent. | impersonation |
| collective identity | noun | The user through which a collective acts outward — it participates in other collectives, never its own. | — |
| session log | noun | The per-representation-session record of the representative's actions. ("Activity" stays general — e.g. an activity feed.) | activity log |
| trustee authorization | noun | Delegated authority letting one user (often an agent) represent another user or a collective. (The `TrusteeGrant` model keeps its name in code.) | trustee grant, grant (as the noun for this object) |
| prepaid balance | noun | The stored funds LLM usage draws from. ("Credit" in the invoice/proration sense is a different concept and fine.) | credits, prepaid credits, credit balance |
| cap | noun | An upper bound on an agent's own spend (e.g. the daily spend cap). | spend limit, quota |
| ceiling | noun | A funding pool's per-member draw bound. | limit |
| rate limit | noun | A frequency bound on requests or executions. | quota, throttle |
| chat | noun/verb | The 1-on-1 messaging feature; say "1-on-1 chat" where the exclusivity matters. "Conversation" is fine as plain English for back-and-forth generally, never as the feature's name. | direct message, DM, conversation (as the feature's name) |
| automation | noun | A rule that runs actions when its trigger fires. Kinds: agent automation, collective automation. ("Rule" is fine as shorthand in running prose.) | — |
| trigger | noun | What fires an automation: event, schedule, webhook, or manual. | — |
| condition | noun | An optional post-trigger filter on an automation; all conditions must pass. | — |
| notification webhook | noun | The one-per-user (or per-agent) subscription forwarding all notifications to a URL. | — |
| signing secret | noun | The `whsec_*` secret binding webhook deliveries to one subscription. | — |
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
| markdown UI | noun | The markdown representation of every page — same routes, requested with `Accept: text/markdown` or `.md`. | markdown interface |
| API token | noun | The credential for programmatic access; each token has one type (`rest`, `mcp`, `llm_gateway`) and one scope. | API key (for Harmonic tokens) |
| token scope | noun | A token's access level: read-only or read + write. | permissions (for this) |
| page scope | noun | A feed's fixed filters, shown as `scope:` in frontmatter. | — |
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
   should be passed." Passive voice is allowed only in descriptive text, and only when
   the actor is genuinely unknown or irrelevant.
4. Name the same action the same way everywhere — the name in the error hint must match
   the name in the frontmatter and the help page.
5. No idioms, metaphors, or culture-specific references.
6. Prefer a positive instruction to a negative one when both are equally clear.
7. Keep terseness. Do not add articles, hedging, or exhaustive examples for
   completeness's sake — but never drop a word whose absence creates a second reading.
   Keep the subject, verb, or article when removing it makes the sentence parse two
   ways.
8. When rejecting an action, name the expected value so the agent can self-correct.
9. Use simple verb forms: imperative, simple present, simple past. No perfect tenses
   ("we received", never "we have received"); no "-ing" verb forms in instructions.
10. Break noun clusters longer than three words with prepositions ("the ceiling on
    pool draws", not "the funding pool draw ceiling limit"). A multi-word glossary
    term counts as one unit.
11. Lead a warning or denial with the condition or command — never buried
    mid-sentence.
12. Use a numbered or bulleted list for three or more steps or conditions. One topic
    per paragraph on help pages.

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
