# Agent Personas: Trio (Melody, Counterpoint, Cadence)

Status: IMPLEMENTED on branch `agent-personas-melody-counterpoint`
(3 commits, 2026-07-18), PR pending. The design evolved substantially
during implementation — this doc's original plan is superseded by what
shipped; the summary below is authoritative.

## What shipped (supersedes the plan below)

- **Trio names the FEATURE** — the ensemble of three built-in personas.
  The agent formerly named Trio was RETIRED (not renamed); **cadence** is
  net-new like melody and counterpoint. All three are instances of one
  pattern: same single mention-responder default automation, no special
  cases, available everywhere including private workspaces.
- **Framing**: melody = doing (expert in Harmonic's features and controls,
  automator role); counterpoint = verifying (rules and boundaries,
  moderator role); cadence = learning (information architecture,
  summarizer role).
- **One feature flag** — the existing `trio` key — enables the set; no
  per-persona toggles. `Tenant#trio_enabled?` / `Collective#trio_enabled?`
  are the ensemble predicates.
- **Roles**: each active persona holds persona role + shared `trio`
  ensemble role + capability role, all activator-managed. @trio fans out
  to every enabled persona (up to 3 replies) and renders as a link to the
  collective; @cadence/@melody/@counterpoint resolve per persona.
- **Structure**: `Personas` registry (identity facts + prompts under
  app/services/personas/prompts/), `PersonaSeeder`, `PersonaActivator`
  (set-level activate!/deactivate!/reconcile!; reconcile heals partial
  ensembles). `RetireLegacyTrioAgents` migration retires old trio users in
  place (rows kept for attribution) and fail-fast-guards the new handle
  namespaces, exempting matching system agents (code-before-migrate
  deploys legitimately seed personas early).
- **Copy policy**: agents are "they", never "it" (see memory). Help topic
  is `/help/trio`, titled "Trio"; "built-in agents" stays a distinct
  generic concept for possible future non-Trio built-ins.
- **Deploy prerequisites**: retire the prod external melody agent (its
  "melody" handle trips the migration guard — intended), and set
  CADENCE/MELODY/COUNTERPOINT_DEFAULT_MODEL env vars (TRIO_DEFAULT_MODEL
  is gone).

---

Original plan below, kept for history. Where it conflicts with the
summary above, the summary wins.

## Goal

Two new built-in personas alongside trio, completing the perspective triad:

- **melody** — makes sure good things DO happen; expert in Harmonic's features
  and when to use them; holds `melody` (persona role) + `automator`
  (capability role).
- **counterpoint** — makes sure bad things DON'T happen; expert in group
  dynamics, security, and trust; holds `counterpoint` + `moderator`
  (capability-less until the moderation-controls track lands).
- **trio** — makes sure whatever happens is documented and contextualized;
  expert in big-picture context and how things connect; holds `trio` +
  `summarizer` (summarizer's cycle-summary and agent-context-curation work is
  deferred, tracked in the overview).

## Inherited from PR #504 (free — written against `system_role.present?`)

Collective identity as principal; pool draw authorization
(`PayerResolver.collective_principaled?`, `User#collective_pool_agent?`);
stripe-gateway routing on billing tenants; TrusteeGrant skip; internal-mode
runtime. From component 2: handle pattern, prefix reservation, persona-role
mention resolution — melody/counterpoint add entries, not mechanisms.

## Changes

1. **`User::SYSTEM_ROLES`** → `["trio", "melody", "counterpoint"]`.
2. **`ReservedHandles::AGENT_ROLES`** → three entries (tag → persona role);
   prefix reservations for `melody-*` / `counterpoint-*`.
3. **Seeder/activator generalization**: parameterize TrioSeeder/TrioActivator by
   a persona definition (name, system_role, capability role, default
   automations, prompt source, default-model env var) rather than cloning them.
   The "sole creator of system_role users" security test generalizes to the one
   seeder. Structural link: see open decision 1.
4. **System prompts**: `Melody::SystemPrompt` / `Counterpoint::SystemPrompt`
   static sources (the `Trio::SystemPrompt` pattern; `effective_identity_prompt`
   dispatches on system_role). Prompts encode the perspective + function; the
   capability role is granted at activation, not merely described in prose.
5. **Default automations per persona**:
   - trio: keeps its three (mentions/replies, decisions, commitments).
   - melody: respond to mentions/replies, plus whatever makes her *proactive* —
     needs design (see open decision 3); v1 can ship mention-shaped only.
   - counterpoint: respond to mentions/replies; evaluation-flavored defaults
     need design; v1 mention-shaped only.
6. **Pool auto-funding**: `Collective#ensure_trio_funded!` →
   `ensure_personas_funded!` — every active persona attaches to the open pool;
   detach guard covers all persona users; dispatch error copy de-trios
   ("This agent runs on the collective's funding pool…").
7. **Activation & packaging**: per-persona feature flags (`melody`,
   `counterpoint`) joining `trio` in `PAID_FEATURE_FLAGS`, reconciled the way
   trio's is (see open decision 2). `downgrade!` clears all three.
8. **Models**: per-persona default-model env vars
   (`MELODY_DEFAULT_MODEL` / `COUNTERPOINT_DEFAULT_MODEL`, falling back like
   `TRIO_DEFAULT_MODEL`); all must be gateway-resolvable on billing tenants.
9. **Copy/docs**: help pages (persona table: perspective, function, role),
   settings copy, feature-flag descriptions, `docs/BILLING.md` mentions of trio
   as the pool's automatic spender become persona-general.

## Prerequisite: retire prod melody

Decided: the production external agent named melody (harmonic-bridge,
DigitalOcean VM) retires; the persona succeeds the name. This MUST land before
this component reaches prod — the moment "melody" enters `AGENT_ROLES`, the tag
becomes collective-local and `@melody` mentions stop resolving to the external
agent through the tenant handle index. Retirement checklist: wind down the
bridge VM / Cloudflare tunnel, archive the agent user (its tokens die with it),
note in ops log. (The `melodic-agent` repo archive was already an open item.)

## Structural note

The persona-role/`persona_user` generalization (and trio_user_id removal) lands
in component 2; this component adds `melody`/`counterpoint` entries to existing
mechanisms — the seeder/activator parameterization in change 3 is the only
structural work left here.

## Open decisions

1. **Packaging**: personas activated individually (three toggles) vs. as a set.
   Individual assumed (matches the existing trio flag shape).
2. **What makes melody proactive**: scheduled automations? broader event
   triggers (`note.created` without mention-filter)? This is the main net-new
   product-design question in this component; v1 shipping mention-shaped
   defaults keeps scope small while the prompt still sets the participatory
   voice.
3. **Pool spend defaults**: per-persona `llm_daily_spend_cap_cents` defaults
   (three ambient agents vs. one), and whether adding personas to an
   already-funded pool triggers a member notification.
4. **Private workspaces**: workspace-trio exists; melody/counterpoint in
   workspaces assumed OUT for v1.

## Tests (red-green)

- Seeder (parameterized): per-persona user_type/system_role/handle/principal/
  prompt/model; sole-creator security test.
- Activator: persona + capability roles granted on activate, removed on
  deactivate; default automations seeded per persona.
- Pool: all active personas auto-funded on pool open; each refused detach;
  PayerResolver draws for melody/counterpoint (should pass via #504's rule —
  pin it).
- Mention: `@melody` / `@counterpoint` resolve collective-locally; prefix
  reservations enforced.
- Flags: paid-tier gating; downgrade clears and deactivates all personas.

## Size

Medium (small if open decisions 1–3 resolve conservatively). One PR.
