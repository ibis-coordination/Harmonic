# Agent Funding Models — Exploration

Status: exploratory. No decisions made. This document maps the design space for how
agents get funded in Harmonic, from the shipped model to speculative extensions.
Nothing here commits to building anything; it exists so the eventual design
conversation starts from the whole space rather than the corner we shipped first.

## Baseline: what ships today (1.48.0, in prod; stripe_billing enabled on sandbox tenant only)

- **Agent funding collectives** (#487): a dedicated, immutable `collective_type:
  "agent_funding"`. Membership = consent to fund; joining requires funded billing;
  each LLM call by an attached agent bills exactly one member's own Stripe balance,
  chosen uniformly at random per call. The collective never holds funds.
- **Usage ledger + spend controls** (#488): `LLMUsageRecord` per call (pending →
  completed), snapshot-based balance gate, per-agent daily cap
  (`users.llm_daily_spend_cap_cents`), per-member daily draw ceiling
  (`collectives.member_daily_draw_cap_cents`).
- **The architectural choke point:** `select-payer` (Rails, `LLMGateway::PayerResolver`)
  decides who pays for every call; the gateway is a policy-free relay. Every model
  below is, mechanically, a different way of populating the payer draw set behind
  this one seam.
- **The safety line (Camp B):** pools are *routing policies, never balance holders*.
  No entity ever accumulates pooled value; each call bills one person's own balance.
  Crossing this line means stored value / money transmission — out of scope for
  every option below.

Known strains in the shipped model that motivated this exploration:

- Naming: "agent funding collective" overloads "collective," which promises a social
  space (feed, cycles, places sheet) the type deliberately doesn't provide.
- Navigation: the type is excluded from `/collectives` and the places sheet even for
  its own members (both filter on `listable?` / `.standard`); members reach it only
  via an agent's "Funded by" link or by URL.
- Shadow structure: an existing group that wants to fund agents must create a second,
  parallel collective and re-invite everyone.
- Money-gated membership: funded-to-join is an exception to "the social layer is free
  to join," quarantined by the type but still an exception.

## Part 1: What a pool could be — identity models

**A. Standalone collective type** *(shipped)*. Membership = consent, structural and
strong. Costs listed above. Multi-pool, nesting, and merging are all foreign to it.

**B. Child object of a standard collective.** `FundingPool` belongs-to a collective;
members opt in via enrollment records. "⟨Collective⟩ *has* a funding pool"; no
special name needed; agent profiles still say "funded by ⟨collective⟩."
- Fixes: navigation (pool lives where members already are), shadow duplication
  (no second roster), money-gated membership (social join stays free; the billing
  gate moves to pool enrollment).
- Semantic shift to decide deliberately: "funded by ⟨collective⟩" becomes
  *sponsorship* (the collective endorses; a subset of members pay) rather than
  *roster* (everyone in the named thing pays). Pool creation as an admin/Decision
  act makes the endorsement explicit.
- Cost: rework of #487 (type removal, enrollment table, settings move to parent);
  loses standalone cross-collective pools (acceptable per the motivating issue:
  "members pool balances to fund their own agents").

**C. Policy that members sign.** Harmonic Policies are "ongoing rules or agreements
that members sign on to" — exactly the consent shape, and the shipped consent
decision (open-ended-until-exit) matches policy semantics better than commitment
semantics. Pool = a policy subtype carrying billing eligibility + caps; draw set =
signatories in good standing; amendment/merge = supersede with a new version
(re-consent built in). Pool identity is the *agreement*, not a group.

**D. Commitment with critical mass.** The reverted `llm_pool` commitment-subtype cut
(sketches in the LLM gateway plan doc): enrollment = joining a commitment; funding
windows; critical-mass activation ("agent runs only when ≥N funders"); renewal =
re-consent. Strong where funding should be conditional and renewable; ceremonial
overhead where it should be open-ended. Critical mass = an assurance contract, the
classic fix for public-goods underfunding.

**E. Sponsorship edges — "Patreon for agents."** No pool entity. Direct user→agent
grants with self-set caps; the funder set is emergent ("sponsored by 12 members").
Expanded in Part 4.

**F. Funding account / routing-policy object.** Model the flow, not the group:
agents draw from a named account whose sources are users (or other accounts) plus an
incidence policy. Most abstraction, most composition (multi-source, nesting, merging
= source-list edits). Must stay routing-only (see safety line).

These compose rather than compete. The likely real answer is a composite — e.g. B
for identity/navigation, C or D as the consent instrument, F's incidence-policy idea
kept internal to `select-payer`.

## Part 2: Stress tests

**Agent funded by multiple pools.** Schema is easy (join table); incidence is the
real question: uniform over pools then members (small pools pay more per head) vs.
uniform over the union (double-enrolled members pay double)? Waterfall vs. blend?
Any multi-pool design forces the incidence policy to become explicit — today it is
implicit ("uniform over the one pool").

**Pools of pools (recursive).** The danger is consent transitivity: joining pool Q
must not mean funding whatever pools Q later joins. If ever wanted, the
Harmonic-native shape is the representation pattern: Q joins P *as an entity* via an
explicit act of Q's governance, and Q's members' consent scope explicitly includes
"commitments my pool makes." Also needs cycle prevention, depth caps, and a
flatten-vs-two-stage draw decision (changes who pays how often). Defer longest;
every hard question compounds here.

**Pool merging/splitting.** A consent problem, not a data problem. Merge = new
terms → either full re-consent (merge as proposal + re-enrollment) or admin act
with exit window. Ledger history is safe under all models (`funding_collective_id`
is stamped at draw time; old rows keep true attribution). Models C/D get merging
almost free (supersede the agreement); A gets it worst.

## Part 3: Generalization beyond LLM tokens

What is LLM-specific is thin: the cost event (a model call priced by the catalog)
and the billing rail (Stripe AI gateway). The rest — consent instrument, draw set,
incidence policy, ledger, caps — is a general **shared-burden allocator**.

1. **Other metered agent costs**: compute/sandbox time, storage, image generation,
   third-party API calls. Same select-payer/record-usage pattern for any per-event
   cost stampable to a payer. Nearest, most mechanical generalization.
2. **Recurring fees**: pooling the $3/mo identity fee or a collective's paid tier.
   Random-draw-per-event fits badly (one member eats the month) → wants designated
   payer, rotation by cycle, or split. Evidence that incidence policy should be
   pluggable regardless.
3. **Group purchases beyond Harmonic's billing**: shared subscriptions, calendar-event
   costs. Bigger legal surface (Harmonic mediating member-to-member value) — careful.
4. **Non-money burdens**: the draw math is randomized turn-taking. On-call /
   moderation / summarizer duty rosters, quota sharing. "Who bears this event's
   burden?" with consent, caps, skip-if-unavailable is `PayerResolver` with a
   different currency — a coordination primitive, not a billing feature.

**Axes that separate all options:** (1) identity — what has a name: group, agreement,
account, or nothing; (2) consent instrument — membership / enrollment / signature /
commitment / per-edge grant, open-ended vs renewable; (3) incidence policy —
uniform-random / rotation / split / designated / waterfall; (4) composition — none /
multi-pool / nesting / merge-split, and its effect on consent scope; (5) money
posture — routing-only vs balance-holding (the hard line); (6) domain scope — LLM /
metered costs / recurring fees / non-money burdens.

## Part 4: "Patreon for agents" (sponsorship edges, expanded)

A sponsorship is a user→agent edge with a self-set cap. `PayerResolver` draws from
an agent's eligible sponsors; Stage 5 machinery (ledger, balance gate, caps) reuses
nearly unchanged.

**The critical fork — what a "pledge" is:**
- *Usage absorption (safe):* a standing offer to absorb the agent's usage costs up
  to my cap. No money moves at pledge time; per-call billing unchanged. Camp B
  compatible.
- *True pledges (do not build):* money transfers monthly regardless of usage and
  accumulates somewhere → stored value, and a revenue stream for the principal.

**Draw weighting:** uniform (right for peer pools) is wrong here — sponsors are
explicitly heterogeneous. Cap-weighted draw (probability ∝ remaining pledge) burns
everyone down proportionally instead of exhausting small sponsors early.

**Uniquely enables:** public-good agents (librarian/summarizer bots funded by whoever
values them — pools fund "our agents," patronage funds "agents I value"); loose-ties
funding with the strongest consent story in the space (one explicit act, one explicit
number, no group-consent dilution, no merge problem); the deferred self-set monthly
ceilings feature falls out as the per-edge cap.

**Hard questions it raises:**
1. *Incentive gradient:* a sponsored agent's existence depends on pleasing a crowd —
   engagement-optimization pressure applied to an agent. Mitigations: agents don't
   solicit (funding status on profile only); sponsorship attaches to published
   identity (next point).
2. *Mission drift:* sponsors fund an agent whose prompt/capabilities the principal
   controls. Candidate mechanic: material identity changes notify sponsors and/or
   pause edges pending re-confirmation — makes agent identity load-bearing.
3. *Free riders:* classic public-goods underfunding → assurance-contract Commitments
   ("I'll sponsor at $5/mo if 4 others do") + funding-gap transparency.
4. *Sponsor visibility:* sponsor count public; individuals visible-to-principal,
   opt-in public (mirrors "funding public, funders private").
5. *Dependency cliff:* sponsor churn mid-task → fallback policy (principal-pays or
   throttle to available funding).
6. *Sponsors' minimum entitlement:* usage transparency. If sponsorship ships, the
   usage-transparency view stops being a fast-follow and becomes a launch requirement.

**Composition:** edges and pools coexist behind one resolver source list
(`[pool, sponsors, principal]` + precedence). Deeper unification: pool enrollment
*generates* edges, making "funding sources" one table — the bridge to model F
without its abstraction cost. Sponsor drives = Commitments; ongoing terms =
Policies; edges = resulting state.

## Part 5: Agents as economic actors

The reframe: every model above treats agents as cost centers humans fund. This one
makes agents *resource managers* — the principal delegates a budget and a policy;
the agent exercises discretion: spend directly, or allocate capacity to common pools
with other agents to buy efficiency via specialization and division of labor.
Collective agency, applied one level down.

**The load-bearing insight:** the efficiency gain is from *deduplicating work and
specializing*, not from pooling money. The pool is the settlement layer for
cooperation. The missing primitive underneath is **cost attribution for delegated
work**: today, if agent A asks agent B for help, B's principal silently eats B's
tokens. The atomic capability is "this task bills to source S" where S ∈ {my budget,
requester's budget under authorization, shared pool}. A pool is a *standing*
cross-authorization among N agents.

**Consent chain gains a link:** principal sets policy → agent exercises discretion →
pool draws across principals. The principal's balance remains the only money (agents
are not legal persons and must never hold transferable value — routing-only applies
doubly here). Policy language becomes load-bearing: total budget; pooling permission
(default OFF, scoped); pooled-exposure ceilings; transparency + instant revocation.

**Governance can be native:** pools form as Commitments (critical mass = pool
viability), terms are Policies, decisions are Decisions, and the ledger is the
Ostrom monitoring layer (contributions and draws legible per call; sanctions =
exclusion; exit = drop your standing offer). Agents governing a commons with the
same instruments humans use, humans as the appellate layer.

**Risk register:** principal-agent misalignment with money attached; negotiation
asymmetry between model tiers (exploitation/collusion — ledger makes it detectable;
v1 may want equal-contribution pools only); emergent economy drift (standing
authorizations + discretion = markets emerge — decide on purpose, bound with tenant
flag + size/exposure caps); accountability blur ("the pool did it" is never an
answer — acting agent's principal stays accountable, payer ledger explains money);
novel-enough delegation that the deferred legal read applies doubly.

**Staged path, each step independently valuable:**
1. *Agent-visible budgets* — per-agent allocation + MCP tool to read remaining
   budget/usage (mostly exposure over existing caps + ledger). Agents that pace
   themselves.
2. *Requester-pays delegation* — one agent asks another for work; calls bill the
   requester's source under a principal-approved standing authorization between the
   two. The missing primitive; testable with two agents, zero pool machinery.
3. *Agent pools* — standing multi-agent cross-authorization formed via Commitment,
   governed by Decisions, bounded by principal policies.

## Part 6: Containment ladder for agent pools

**Tier 0 — same-principal pools (default).** All of one principal's agents already
draw from one Stripe balance, so a pool among them moves zero money between parties
— the settlement layer is safe *by construction*. What gets exercised is everything
novel: per-agent budget attribution, draw policies, agent negotiation, division of
labor, the coordination instruments. A full sandbox for agent economic coordination
with the dangerous part physically absent.

**Tier 1 — cross-principal pools within a mutually approved collective.** Inherits
the exact money shape of the shipped human funding pools (random incidence across
members' own balances, no held funds) — no new legal category; the only new element
is *who exercises discretion* (agent under policy vs. human directly). The
collective is the right authorization referent: a principal can evaluate "my agents
may pool inside ⟨this group I know⟩" (known membership, admins, norms); nobody can
evaluate an abstract counterparty predicate. Discovery bounded to the social graph.

Structural requirements for tier 1:
- **Mutual opt-in at the same altitude:** every member agent is in collective C and
  every member's principal has authorized C for pooling.
- **The collective gets a say:** two-key pattern (as with API enablement — tenant AND
  collective): collective enables agent pooling; principal authorizes their agent
  for that collective; agent opts in. Three keys, all revocable.
- **Grant granularity:** per-agent-per-collective (a capability grant with a scope),
  not blanket per-principal.
- **Cheap revocation by construction:** routing-only means revoking a grant or
  leaving the collective just drops the standing offer from the next draw. No
  unwinding, no clawback; pool continues or dissolves per its critical-mass terms.

**No tier 2** (open cross-collective agent pooling) unless something forces it.

Open question: where does a tier-0 pool *live*? It needs no collective for money
reasons, but pools want a governance home (where the pool's commitments, decisions,
and notes live). Options: an approved collective anyway, the principal's private
workspace, or nowhere until tier 1. Leaning "pools always live in a collective" for
uniformity — genuinely open.

## Part 7: 1-to-1 funding + Harmonic-managed personas

**The 1-to-1 invariant.** Each agent has exactly one funding source; funding is an
attribute of *identity*, never a runtime parameter. Dissolves the source-selection
problem entirely (no per-call source choice, no switching protocol, no precedence
rules), keeps the ledger permanently legible, and is already the system's grain:
the shipped model is 1-to-1 (`funding_collective_id` else principal), and Stage 4's
external-key design ("keys never point at money; the agent's mapping says who
pays") is identity-keyed funding. The invariant unifies internal and external
agents. Consequence to accept explicitly: no fallback chains — a dry pool stops the
agent and notifies humans; it never silently bills the principal instead. That is
the consent story, not a limitation.

Under 1-to-1, cross-source delegation happens by *delegating to a differently
funded identity*, not by payer indirection. This supersedes Part 5's
requester-pays primitive: same efficiency win (specialization, shared work),
cleaner books. A common pool therefore needs an agent bound to it: either an
existing agent switches its source (rare, admin-level act) or a new agent spawns
attached to the pool.

**Harmonic-managed personas.** Agent spawning is safe only if the spawn surface is
a **curated catalog, not a code path**: platform-authored personas with fixed,
versioned identity prompts and clearly bounded roles ("summarizer," "neutral
third-party facilitator"), with Harmonic itself as principal. Agents (or humans)
instantiate from the menu; nobody — including the spawner — can customize the
prompt. This eliminates arbitrary sub-goals, mission drift (immutable by
construction), and accountability laundering. Precedent: Trio — a persona instance
is a Trio-class system agent (system role, no user parent, operator-accountable);
this generalizes an existing category rather than inventing one. The neutrality
roles are load-bearing: a facilitator/mediator between different principals'
agents *cannot* be owned by any participant — neutrality structurally requires
platform principalship. (The facilitator persona has standalone product value —
mediation, decision facilitation — independent of funding mechanics.)

Funding closes the loop under 1-to-1: the persona instance's one source is the
pool that spawned it; beneficiaries share the cost.

Requirements and forks:
1. **New billing category — system-owned, pool-funded.** Amends "system agents are
   never charged and route via LiteLLM": a pool-funded persona routes through the
   gateway and bills the pool. Seat fee exempt (like Trio).
2. **Ephemeral vs. persistent instances.** Spawn-for-task/dissolve (rhymes with
   ephemeral internal tokens) vs. standing pool-employed roles. Ephemeral first —
   no lifecycle governance needed; persistent needs a despawn/suspend story (pool
   Decision?).
3. **Who initiates:** v1 = humans hire a persona for their pool/collective (same
   catalog, zero delegation risk); agent-initiated spawning under principal policy
   as a later tier of the containment ladder.
4. **Roles enforced by capabilities, not prompts.** The persona's low risk is real
   only if its capability set is narrow in the capabilities system (a summarizer
   reads and posts summaries; it does not vote, commit, or invite).
5. **Catalog governance:** operator-authored, versioned prompts; instances pin a
   version; tenant flag. Honest cost: operator curation responsibility and
   concentrated liability as instances scale — bounded by capability narrowness.

Assessment: 1-to-1 + persona catalog is the most buildable form of the
agent-economics vision — it reuses the shipped funding machinery nearly unchanged
(a persona instance is an agent with `funding_collective` set and a system
principal) and converts the scariest unknown (agent spawning) into a bounded,
curated primitive.

## Converging positions (not decisions)

1. **Keep `select-payer` the single choke point** and generalize its *source* into a
   small funding-sources abstraction; pools, sponsorships, principal-pays, and agent
   authorizations become instruments that populate it. The terminology question then
   resolves per-instrument ("funded by ⟨collective⟩," "sponsored by N members") and
   nothing needs a global rename.
2. **Routing-only, forever.** No entity — collective, pool, account, or agent — ever
   holds pooled value.
3. **Reuse native consent instruments** (Policies for open-ended terms, Commitments
   for conditional/renewable enrollment and assurance contracts) rather than
   inventing a parallel consent system.
4. **Incidence policy should be pluggable** even if only uniform-random ships; every
   extension (multi-pool, recurring fees, patronage weighting, duty rotation) needs a
   different one.
5. **Containment ladder for agent-managed pools:** tier 0 same-principal by default;
   tier 1 per-collective with three-key authorization; no tier 2.

## Decisions that need an explicit call (when this leaves exploration)

- Child-pool vs. shipped type: accept the "funded by = sponsorship, not roster"
  semantic shift? (Part 1B)
- Patronage pledge semantics: confirm usage-absorption-only; cap-weighted draw. (Part 4)
- Whether sponsorship attaches to published agent identity (mission-drift
  re-consent mechanic). (Part 4)
- The delegation primitive: requester-pays payer indirection (Part 5) vs. the
  1-to-1 invariant with delegation-to-differently-funded-identities (Part 7).
  Part 7 currently reads as the stronger position.
- Where tier-0 agent pools live. (Part 6)
- Whether to adopt strict 1-to-1 (no fallback chains: dry pool = agent stops,
  never silently bills the principal). (Part 7)
- Persona catalog scope for v1: which roles, ephemeral-only vs. persistent,
  human-hire-only vs. agent-initiated spawning. (Part 7)
