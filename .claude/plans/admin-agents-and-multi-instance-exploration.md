# Exploration: Built-in admin agents and multi-instance cross-monitoring

**Status: exploration — no implementation decisions made yet.** This document maps the design space for (1) built-in agents that monitor app health and perform admin actions, (2) their evolution into customer service agents, and (3) a multi-instance topology where independent Harmonic instances monitor each other.

## Vision

Harmonic operates itself. A built-in "steward" agent watches health signals, triages incidents, and — within carefully bounded authority — performs admin actions. Its workspace is Harmonic itself: incidents are Notes, remediation pledges are Commitments, and approval gates for privileged actions are Decisions. Later, per-tenant customer service agents answer user questions and escalate to humans. Eventually, two or three independent Harmonic instances on separate hardware watch each other, so the steward investigating a production outage is never running on the hardware that just went down.

## Two distinct agent classes — keep them separate

This idea contains two different agents, and blurring them would be a mistake:

1. **Steward / operator agent** (sys/app-admin altitude). Lives in the primary tenant. Cross-tenant by nature. Its central design problem is **authority containment**: what admin power does an autonomous process get, and how is it gated?
2. **Customer service agents** (tenant altitude). Per-tenant. Need *zero* cross-tenant power — mostly read access plus comment/chat writes. Their central design problems are **privacy and tone**, not authority. Architecturally they are close to existing internal agents.

The CS agent is a mild extension of what exists; the steward requires new primitives. Sequence accordingly.

## Existing substrate

The app is unusually well-positioned for this:

- **Agents are users.** `ai_agent`-type `User` rows executed by agent-runner, acting through the same dual interface (HTML/markdown + describe/execute actions) as humans, with normal auth, tenant scoping, capability checks (`CapabilityCheck` over `agent_configuration["capabilities"]`), rate limits, and audit (`McpToolCallLog`, `AgentSessionStep`).
- **Admin surface already speaks the agent's language.** `AppAdminController` and `SystemAdminController` expose `describe_*`/`execute_*` actions — exactly the shape `execute_action` consumes. The blockers are deliberate: `ensure_app_admin` / `ensure_primary_tenant` and `require_reverification(scope: "admin")`.
- **Three admin tiers** already delineate altitude: `SystemAdminController` (infrastructure: Sidekiq, monitoring), `AppAdminController` (cross-tenant: tenants, users, suspension, billing exemption), `TenantAdminController` (single tenant).
- **Tenant-safety architecture**: `unscoped_for_admin(user)` requires an admin role on the acting user; `tenant_scoped_only` for cross-collective. Whatever authority model is chosen must compose with these, not route around them.
- **Sensing inputs exist**: Sentry, Prometheus metrics endpoint, healthcheck endpoint, Slack security alerts (docs/MONITORING.md); `incoming_webhooks` for push triggers; the automations system for scheduled triggers.
- **Coordination primitives**: Notes, Decisions, Commitments, Cycles — usable as the ops workspace and approval mechanism rather than building bespoke incident/approval UI.
- **Funding**: LLM gateway funding pools can pay for steward LLM usage without touching per-user billing.
- **Help pages are agent-readable** (`get_help`), deliberately written for non-human readers — a ready-made CS knowledge base.
- **harmonic-bridge** (npm `@ibis-coordination/harmonic-bridge`, prod-proven on a DigitalOcean VM via Cloudflare Tunnel) is an existing pattern for giving an agent a persistent foothold on a VM outside the app itself.

Related: [agent-runner-external-tools-exploration.md](agent-runner-external-tools-exploration.md) — internal agents currently have only four Harmonic-bound tools. The steward is a concrete motivating use case for that work: talking to a peer instance's `/mcp`, to Sentry's API, or to a cloud provider API are all "external tools" in that document's sense, and its Rails-as-control-plane / runner-as-data-plane hybrid is the natural execution model here too.

## Mechanics sketch (single instance)

- **Sensing, push**: Sentry / Alertmanager / uptime-check webhooks → `incoming_webhooks` → dispatch a steward task run. Needs dedup and rate limiting so an error storm doesn't spawn hundreds of task runs — batch into "one open incident, new evidence appended" rather than task-per-event.
- **Sensing, pull**: scheduled automation ("hourly health sweep") where the steward `fetch_page`s a health surface. **Gap**: admin dashboards (`/sys-admin`, `/app-admin`) mostly lack markdown representations; a machine-readable health page is likely the first new build.
- **Acting**: via `execute_action` against existing admin actions, gated per the authority model below.
- **Workspace**: an ops collective in the primary tenant. Incident = Note (with linked evidence), proposed privileged action = Decision, remediation = Commitment. Humans participate in the incident in the same medium as the agent.
- **Escalation**: web push / email to operators, both already built.

## Design decisions

### 1. Authority model (the central decision)

- **Option A — grant `app_admin`/`sys_admin` role to the agent user.** Maximal reuse, maximal blast radius; makes the reverification gate meaningless on the most sensitive surface in the app. Ruled out as a starting point.
- **Option B — capability enumeration.** Extend the existing agent capabilities mechanism with admin-action grants: `retry_failed_job: autonomous`, `suspend_user: with_approval`, `toggle_billing_exempt: never`. Least privilege; requires controller-side enforcement that an agent's admin access flows *only* through the enumeration (never through role checks). Note the current `CapabilityCheck` fail-open default (nil = all grantable allowed) must be fail-closed for admin capabilities.
- **Option C — observer + propose-only.** Read access to health surfaces; every mutation goes through a human. Cheapest and safest; most of the value (triage, diagnosis, correlation) is here anyway.

Likely path: C first, B as trust develops, A never.

### 2. The agent analog of reverification

Reverification exists because a human session can be hijacked; the agent equivalent is a hijacked or confused agent. Proposed analog: **Decision-based per-action authorization** — the steward proposes a specific action instance ("suspend user X, because Y, evidence Z") as a Decision in the ops collective; a human with the admin role accepts; acceptance authorizes exactly that action instance, with an expiry. Reuses the audit chain and the existing acceptance-voting model. This is a genuinely new primitive (Decision → authorized action execution) and deserves its own design pass.

### 3. Autonomy ladder, per action class

observe → recommend → act-with-approval → act-and-notify → autonomous. Configurable **per action, not per agent**, so trust is earned incrementally: retrying a dead Sidekiq job graduates to autonomous long before anything touching users or billing does.

### 4. Identity, principal, billing

Every agent today has a human principal and bills to them; token-type exclusivity means internal agents hold no user-issued keys. Options: parent the steward to the operator's account (cheap, honest — a human is accountable) vs. a new "system principal" concept (heavier, needed only if operator-parenting distorts billing or the accountability story). LLM usage funded via a billing exemption or an operator-funded pool.

### 5. Containment invariants (non-negotiable under any authority model)

- Cannot modify its own capabilities or configuration.
- Cannot act on admin users; cannot unsuspend itself.
- Rate limits on admin actions independent of the normal API rate limits.
- Kill switch that does not route through the agent system (env var / feature flag read by dispatch).
- Every agent-performed admin action attributable and linked to the triggering signal in the audit chain.

### 6. Who monitors the monitor?

The steward runs on agent-runner, so single-instance it structurally cannot detect an agent-runner outage — the most likely failure it exists to catch. External dumb uptime monitoring stays regardless. The real answer is the multi-instance topology below.

### 7. CS agent privacy boundary

A tenant CS agent should answer with the **asking user's visibility**, not elevated visibility — it must not become a channel that launders private collective content into answers for other users. Representation sessions may already be close to the right mechanism for "act as/for this user." Escalation path: hand off to a human operator with a summary, in-app.

## Multi-instance topology

The idea: two or three Harmonic instances run independently — separate hardware, separate databases, ideally different availability zones or cloud providers. One may be designated the **admin instance**; the other is the actual production instance. Admin agent identities hold accounts on all instances. If one goes down, an agent on a surviving instance investigates.

### Why this is attractive

- **Solves monitor-the-monitor structurally.** The steward watching prod does not run on prod's hardware, DB, or agent-runner.
- **Ops coordination survives the outage.** The incident Note, the evidence, the approval Decisions, and operator notifications all live on the admin instance — the human-in-the-loop mechanism keeps working precisely when prod can't provide it.
- **No new federation protocol needed.** Instance A's steward is simply an external-mode agent with respect to instance B: an account on B plus an `mcp`-type token, hitting B's `/mcp` like any external agent. Cross-instance communication is just... being users of each other. (Cute low-tech liveness option: stewards exchange heartbeats in each other's ops collectives, using the existing heartbeat feature.)

### Scope boundary: observer, not failover

This is **not** HA. No tenant data replication, no traffic failover, no shared database. The admin instance holds ops data only (incidents, evidence, decisions, operator accounts). Treating it as a warm standby is a different, much harder project — explicitly out of scope. Consequence: the admin instance can be tiny (single node), cheap to run, and boring.

### Topology decisions

> **Settled direction (2026-07-24, [north star](agent-built-harmonic-north-star.md)):** three instances with *distinct roles*, not three monitors voting — **staging** (changes land and get exercised first), **production** (approved changes; real users + developer agents), **admin** (hosts the stewards, deliberately runs a few versions *behind* production so a bad deploy never breaks the watcher the same way as the watched). The quorum trade-off below is therefore moot in its original form: the third instance exists for release safety, not tiebreaking. The asymmetric watcher analysis and the "peer down vs. network down" ambiguity still apply between admin and production. Staging's monitoring needs are minimal (no real users).

- **Designated-admin (asymmetric) vs. peers (symmetric).** Asymmetric is simpler: prod does the real work; admin instance watches prod, hosts the ops collective, and pages humans. Prod's own steward can watch the admin instance in return (cheap, low-stakes). Symmetric peers only earn their complexity at three instances.
- **Two vs. three instances.** Two instances cannot distinguish "peer is down" from "the network between us is down" — a false-positive page at 3am. Options: accept it (a human gets paged and looks — fine for this scale), use external uptime checks as tiebreaker, or add a third vantage point. Three instances buy quorum but triple the ops burden; probably not worth it until false positives actually hurt. **Since the response to a detected outage is "investigate and notify humans" — not automated failover — split-brain is an annoyance, not a correctness hazard.** This is the strongest argument for keeping the observer-not-failover boundary.
- **Different providers/AZs** kill correlated failure (one provider outage taking out both watcher and watched). Different providers also mean divergent deploy tooling — a real, ongoing ops cost to weigh.

### What "investigate" actually means when the peer is down

If prod's Rails is down, prod's `/mcp` is down; the app-level account on prod is useless at exactly the interesting moment. Tiered diagnosis, in escalating depth:

1. **App level**: peer `/mcp` and healthcheck endpoint — distinguishes "app degraded" from "app gone."
2. **Edge/external level**: uptime checks, Sentry API, DNS/TLS checks — is it down for everyone or just for me?
3. **Infra level**: a harmonic-bridge-style foothold on (or adjacent to) the prod host — container status, disk, logs, possibly restart authority. This is where investigation gains teeth, and where risk concentrates.
4. **Provider level**: cloud provider API/status — is the VM even running? Is it a provider incident?

Levels 2–4 all require external tools the runner doesn't have yet — again converging on [agent-runner-external-tools-exploration.md](agent-runner-external-tools-exploration.md). Level 3+ authority (restart services, reboot VMs) should sit at the top of the autonomy ladder: propose-only until proven, and arguably propose-only forever.

### Credential blast radius

The admin instance holds credentials with power over prod: an mcp token on prod, possibly bridge/SSH footholds, possibly cloud API keys. If the admin instance is compromised, the attacker gets whatever those credentials allow. Mitigations mirror the single-instance authority model: read-mostly tokens; approval-gated mutations (approvals granted by humans *on the admin instance*, so a compromised prod can't self-approve — but note the inverse: a compromised admin instance is now the approval authority, which is why its credentials on prod must be weak by default); scoped, rotated infra credentials; and the admin instance being small and boring makes it easier to keep patched and locked down.

### Consistency questions

Admin agent identities exist on all instances ("same" agent, different User rows, different DBs). Keep this loose: no identity federation, just conventionally-matched accounts. The ops collective on the admin instance is the single source of truth for incidents; anything the steward does on prod links back to it by URL.

## Phased sketch

- **Phase 0 — triage loop, no new authority.** Ordinary internal `ai_agent` in the primary tenant, ops collective, scheduled health-sweep automation against a new markdown-rendered health page, posting triage notes. Also: webhook → dispatch plumbing with dedup. Proves whether the triage output is useful before investing in authority primitives.
- **Phase 1 — propose-only + notify.** Steward proposes actions as Decisions with evidence; humans execute manually. Escalation via push/email. Still zero admin capability.
- **Phase 2 — Decision-authorized execution.** The reverification-analog primitive: accepted Decision authorizes one specific action instance, agent executes it, audit chain links proposal → approval → execution. Capability enumeration (fail-closed) for which actions are proposable/executable at all.
- **Phase 3 — second instance.** Minimal admin instance, cross-instance steward accounts, liveness watching, tiered investigation (app + external levels first; infra foothold later and propose-only).
- **Phase 4 — CS agents.** Per-tenant, asker's-visibility answering from help pages + tenant content, human escalation. Can proceed in parallel with 1–3 since it shares almost nothing with the steward's authority problem.

## Open questions

- What belongs on the machine-readable health page, and does exposing it create an information-disclosure surface that needs its own auth tier?
- Does Decision-authorized execution need a new model (`AuthorizedActionGrant`?) or can it live as metadata on the Decision + a check at execute time?
- Incident lifecycle: when is an incident Note "closed," and who/what closes it?
- Steward model choice and cost envelope — health sweeps are frequent; how cheap can the sweep be while staying useful (small model for sweeps, escalate to a big model on anomaly)?
- Where do prod-side credentials for the admin instance's steward get stored and rotated (relates to the unresolved ActiveRecord encryption gap noted in the external-tools exploration)?
- Is the admin instance a normal Harmonic deployment with a tiny footprint, or a stripped profile (no billing, no public signup)?
