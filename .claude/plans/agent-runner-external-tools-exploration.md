# Exploration: Giving agent-runner agents more tools (web search, external MCP, other APIs)

**Status: exploration — no implementation decisions made yet.** Notably, the execution locus is an open question with a real tension: routing external tool calls through Rails would reuse its authorization/audit machinery, but the agent-runner was built in TypeScript specifically for async-IO concurrency — and external tool calls are exactly the kind of slow, third-party-controlled IO that motivated moving agent work off Ruby threads in the first place.

## Context

Internal AI agents (the ones executed by the agent-runner service) can currently only touch Harmonic itself. Their entire tool surface is four Harmonic-bound tools — `fetch_page`, `execute_action`, `search`, `get_help` (plus `respond_to_human` in chat mode). This document explores how agents could gain broader abilities: web search, third-party MCP tools, or generally a way to talk to APIs beyond Harmonic — and, at the far end, full coding environments on persistent workspace machines.

## How tools work today (verified)

**Runner side** (`agent-runner/`, Node.js + Effect.js — not the Claude Agent SDK). Three hardcoded layers must agree:
1. `agent-runner/src/core/AgentContext.ts` — `AGENT_TOOLS` descriptor array + "You have four tools…" prompt prose.
2. `agent-runner/src/core/ActionParser.ts` — `switch (name)`; unknown tool names become errors (line ~111), which guards against hallucinated tools.
3. `agent-runner/src/services/AgentLoop.ts` — `switch (action.type)` dispatch (lines ~423–473).

Every tool call becomes a stateless JSON-RPC `tools/call` POST to Rails `/mcp` via `agent-runner/src/services/McpClient.ts` (ephemeral Bearer token, 30s timeout). `McpClient` already contains a fully generic `callTool(name, args, …)` internally — it's just not exposed on the service interface. The runner never calls `tools/list`; discovery is static. Every step (tool call, think, error) is already reported to Rails incrementally via HMAC-signed `/internal/agent-runner/tasks/:id/step` — this is the existing audit conduit for anything the runner does.

LLM calls go through LiteLLM / Stripe gateway with heterogeneous models (Arcee trinity default, Claude, GPT, local Ollama) — so provider-native tools (e.g. Anthropic's server-side web search) are not a universal answer. Runner config is env-only; per-agent data arrives in the encrypted Redis task payload (there is an established AES-256-GCM pattern for secrets in that payload: `TokenCrypto.ts` / `AgentRunnerCrypto`).

**Rails side:**
- `Mcp::EndpointController` (`app/controllers/mcp/endpoint_controller.rb`) is the MCP server: static `TOOL_DESCRIPTORS` (4 tools, no per-caller filtering on `tools/list`), hardcoded `case name` in `tools/call`, dispatch through `MarkdownUiService` → internal integration-session request → full ApplicationController auth stack.
- Audit: `McpToolCallLog` per call; `AgentSessionStep` timeline links via `mcp_tool_call_log_id`.
- Grants: `CapabilityCheck` (`app/services/capability_check.rb`) — `agent_configuration["capabilities"]` where **nil = all grantable allowed (fail-open)**, plus always-allowed/always-blocked lists and ~20 UI groups.
- Rate limits on /mcp: 10/s + 60/min per token, 600/min per principal, 6000/min per tenant; 256 KiB request / 1 MiB result caps.
- Agents are `User` rows with jsonb `agent_configuration` (identity_prompt, mode internal/external, model, capabilities, allow_public_writes, scratchpad) — the natural home for per-agent tool grants regardless of where execution happens.
- **Reusable precedents:** `ssrf_filter` gem for SSRF-safe outbound HTTP in `app/services/webhook_delivery_service.rb`; cost pattern `AiAgentTaskRun#estimated_cost_usd`; tenant toggles in `Tenant#settings` jsonb.
- **Gap:** ActiveRecord encryption is not configured — storing third-party credentials at rest requires setting up `config.active_record.encryption` keys (or reusing the HKDF/AES-GCM approach already shared between Rails and the runner).

**External-mode agents** (harmonic-bridge / Claude Desktop / Cursor) hit `/mcp` from their own harnesses — but those harnesses already bring their own web search, file access, and MCP client support. Internal agents are the tool-poor ones; giving *them* tools does not require the tools to live on `/mcp`.

## The core architectural tension

**Concurrency.** The runner exists because each agent task blocks 5–60s per LLM call, and Node `await` handles hundreds of those concurrently where Ruby threads can't. External tool calls (web fetches, search APIs, third-party MCP servers) have the same profile: slow, bursty, controlled by someone else. Executed runner-side, 100 concurrent fetches cost approximately nothing. Executed Rails-side, each one holds a Puma thread for its full duration — reimporting the exact problem the runner was built to escape, into the tier that serves human page loads.

**Authority.** Rails is the single authority for who an agent is, what it may do, what it did (audit), and what it cost (billing). None of that machinery exists runner-side today.

These pull in opposite directions only if "execution" and "authority" are forced into the same place. They don't have to be:

> **Hybrid: Rails as control plane, runner as data plane.** Rails decides *which* tools an agent has (grants in `agent_configuration`, delivered in the task payload or via `tools/list`), stores credentials, persists the audit trail, and does billing rollup. The runner *executes* external calls with its async IO and reports each call as a step through the existing `/internal/.../step` conduit — the same way every tool call is already recorded.

## Option survey

### A. Runner-executed built-in tools (`web_search`, `fetch_url`), Rails-controlled

**What:** Add the tools to the runner: `web_search` as a thin client over a search API (Brave/Tavily/Exa/SearXNG), `fetch_url` via undici (already a dependency). Rails grants them per agent (`agent_configuration["external_tools"]`, fail-closed) and the dispatch payload tells the runner which tools to advertise to the LLM. Each call becomes a new step type (e.g. `external_tool`) in `StepBuilder.ts`, reported via the existing step conduit, so it lands in the `AgentSessionStep` timeline the principal already sees.

**What needs building that Rails would have given free:**
- *SSRF guarding in Node.* There's no `ssrf_filter` equivalent bundled; either implement DNS-resolve-then-check-IP (undici supports a custom lookup/Agent), or — cleaner — network-level egress control: the runner container currently sits on both `frontend` and `backend` Docker networks; a dedicated egress path (or proxy) that can't reach `web:3000`/`redis`/`db` makes SSRF structurally impossible rather than filter-dependent. Flag: this is an ops-level design choice worth making deliberately.
- *Rate/cost limiting.* Per-task caps are natural runner-side (e.g. N searches per task, enforced in the loop — analogous to `max_steps` and `RetryBudget`); per-tenant/per-principal aggregates would need Redis counters (runner already has Redis) or Rails-side accounting from step reports.
- *Cost attribution.* Search API per-call price stamped on the step detail; Rails rolls it into `AiAgentTaskRun#estimated_cost_usd` on complete (pattern already exists for tokens).
- *Secrets.* A platform-wide search API key is just runner env (like `STRIPE_GATEWAY_KEY`) — no new machinery for stage 1.

**Strengths:** aligned with the runner's whole reason for existing; zero new load on the web tier; timeouts/retries in the loop that already owns per-task budgets; `LeakageDetector` canary is runner-side and can scan outbound tool args (URL/query) before the request leaves — the URL query string being the classic exfiltration channel for a prompt-injected agent.
**Costs:** no `McpToolCallLog` row per call unless we add one (steps may be enough — open question); audit/limits logic split across two codebases; internal-only (external harnesses don't get these tools — but they bring their own).

### B. Runner as MCP client to external MCP servers — the general endgame

**What:** Per-agent registry of external MCP servers (a Rails table — see control plane below); at task start the runner receives the agent's registrations, connects (this is where the official `@modelcontextprotocol/sdk` *is* appropriate — long-lived stateful sessions with third-party servers is exactly what it does, unlike the deliberately hand-rolled stateless Harmonic connection), merges the discovered tools into the LLM's tool list (namespaced, e.g. `ext__github__create_issue`), and dispatches calls. TypeScript is also where the MCP ecosystem lives — client support is mature there in a way it isn't in Ruby (the official `mcp` gem is server-focused; a Ruby client would be hand-rolled).

**Control plane (Rails):** `McpServerRegistration` table (tenant_id, agent_user_id, namespace slug, url, auth kind, encrypted credential, enabled, tool allowlist, pinned tool descriptions). Credentials transit to the runner inside the already-encrypted Redis payload (same AES-256-GCM pattern as the Bearer token) or are fetched at task start via the HMAC internal API.

**Distinct risks (locus-independent — these exist wherever the proxy lives):**
- *Tool-description prompt injection* ("tool poisoning"): a malicious/compromised server's tool descriptions enter the agent's prompt. Mitigate by pinning descriptions at registration time in Rails and requiring principal re-approval on diffs.
- *Credential exfiltration*: creds attached at the transport layer, never placed in the LLM's context, never rendered back in UI.
- *Rug-pull semantics* when a downstream server changes tool behavior between approval and use.
- *Stdio-based MCP servers* (the majority of the ecosystem today) would mean running arbitrary third-party processes inside the runner container — almost certainly out of scope; HTTP-transport servers only.

### C. Rails-executed tools on the hosted `/mcp` endpoint

The previously-drafted direction, kept for completeness. Add tools to `TOOL_DESCRIPTORS` + `handle_tools_call`, execute inline with `ssrf_filter`, gate via CapabilityCheck, log to `McpToolCallLog`. Everything authoritative in one place, and external MCP clients (Claude Desktop etc.) would see the tools too.

**Why it's disfavored:** every external call holds a Puma thread for its full third-party-controlled duration. The runner dispatches up to `MAX_CONCURRENT_TASKS` (default 100) concurrent tasks; a modest number of agents doing web research could pin the web tier that serves human page loads. This is precisely the blocking-IO-in-Ruby problem the runner was created to avoid (see `docs/AGENT_RUNNER.md`, "Why a separate service?"). A sidecar executor or a job+polling contortion could mitigate, but at that point the "reuse Rails machinery" benefit has mostly evaporated — the machinery worth reusing (grants, audit persistence, billing) is available to the runner through existing conduits anyway. Might still make sense someday for offering curated tools to *external* MCP clients as a product feature — a separate question from empowering internal agents.

### D. Provider-native tools via LiteLLM — not the answer, maybe a later optimization

Anthropic/OpenAI server-side web search works only for those providers (default model is Arcee; Ollama has nothing), silently varying capability by model, and the search happens inside the LLM call — invisible to steps, limits, and cost attribution. At most a later grounding optimization for supported models.

### E. Other shapes worth naming

- **Tools as automations**: a `run_automation` tool triggering owner-authored automations (which already deliver SSRF-safe webhooks via `WebhookDeliveryService`). Strong safety posture — the human authors the integration, the agent pulls a trigger — but async results don't fit the synchronous tool loop. Complementary, not primary.
- **Generic `http_request` tool** (agent-supplied method/headers/body): maximal power, maximal SSRF/exfiltration surface, weak audit UX. If ever, per-domain principal-approved allowlists. Not early.

## Cross-cutting concerns

**Grants (locus-independent).** A new `agent_configuration["external_tools"]` key, **default absent = none (fail-closed)** — deliberately NOT folded into the `capabilities` array, because `capabilities: nil` means "all grantable allowed" and would silently arm every existing unconfigured agent with web access. Policy lives in `CapabilityCheck` via a parallel `external_tool_allowed?` (mirroring `public_writes_allowed?`). Layered authority: sys-admin (feature exists + platform keys + kill switch) → tenant admin (`Tenant#settings` toggle) → human principal (per-agent settings UI). Agents must never self-grant (settings actions belong in `AI_AGENT_ALWAYS_BLOCKED`). The dispatch payload carries the granted list so ungranted tools never appear in the LLM's tool list.

**Runner tool plumbing.** Interim: static definitions in `AgentContext.ts` included conditionally from the payload; new `ActionParser` cases; new `AgentLoop` cases; new `external_tool` step type in `StepBuilder.ts` + a Rails timeline renderer (tool, URL/query, status, duration, cost). Target: tool definitions assembled dynamically (payload-driven for built-ins; `tools/list` from external servers for option B), with `ActionParser`'s `default:` branch forwarding *advertised* unknown names as a generic action (preserving the hallucination guard for unadvertised ones) and prompt prose generated from the actual list.

**Prompt injection from web content.** Wrap fetched/search results in explicit untrusted framing (`<untrusted-web-content url="…">`) with a do-not-follow-instructions reminder, consistent with the existing BOUNDARIES prompt section. Scan outbound tool arguments for the LeakageDetector canary before the request leaves the runner (refuse + `security_warning` step on match).

**Audit.** The step conduit already persists every tool call to `AgentSessionStep` with full detail — that is the surface principals actually review. Open question whether external calls also warrant `McpToolCallLog`-style rows (they wouldn't pass through `/mcp`, so it would be a new write from the internal step endpoint, feasible since steps flow through Rails anyway).

**Model capability caution.** Weaker models (the default Arcee trinity) already misuse the existing 4-tool set (see `.claude/plans/agent-runner-observability-and-tool-use.md`). Expanding the tool list amplifies this — an argument for per-agent tool subsetting (which fail-closed grants give us anyway) and for testing across the model roster before adding many tools.

## A plausible staged path (if/when we proceed)

1. **Stage 1 — runner-executed `web_search` + `fetch_url`.** Rails: fail-closed grant key + tenant toggle + settings UI + `external_tools` in the dispatch payload + step-type rendering + cost rollup. Runner: two tools (undici fetch with SSRF strategy TBD, search adapter with env API key), per-task call caps, untrusted-content framing, canary scan on outbound args, `external_tool` step type. Teaches: real cost, abuse patterns, injection incidents, what audit UX principals need.
2. **Stage 2 — egress hardening + limits maturity.** Whatever stage 1 revealed: network-level egress isolation for the runner, per-tenant aggregate limits, McpToolCallLog-equivalent rows if steps prove insufficient for audit.
3. **Stage 3 — external MCP server registry.** `McpServerRegistration` in Rails (encrypted credentials, pinned descriptions, re-approval on diffs); runner connects via `@modelcontextprotocol/sdk` (HTTP transports only), namespaced tool merging, generic dispatch. Teaches: whether the long tail of MCP servers is what principals actually want vs. more curated built-ins.

A separate track — not a stage 4, because it doesn't build on the runner tool plumbing at all — is persistent workspace machines (next section).

## Persistent workspace machines (full coding environments)

A different question from tools: instead of widening the internal loop's tool list, give a granted internal agent its own persistent VM running a real coding harness. Explored against Fly.io Machines (Firecracker microVMs, REST API, sub-second wake from stopped, stopped machines cost ~nothing beyond volume storage); E2B/Modal are the ephemeral-sandbox alternatives if workspaces should be cattle rather than pets.

**The framing that makes this tractable:** Harmonic already has two agent runtimes — the internal runner loop, and external bridge-connected harnesses. A workspace machine is architecturally the second kind, *operated by the platform instead of the agent's owner*. Both prototypes exist: `setup-bridge-agent-on-fresh-vm.sh` is the workspace image (ported to a Dockerfile), and harmonic-bridge is the connectivity pattern. "Internal agents get a coding environment" is largely "automate and multi-tenant the bridge-agent VM setup."

**Do not build the coding loop into the runner.** The current loop (four static tools, 4,000-char truncation, stateless steps, weak default models) is months of harness engineering away from a competent coding agent — work Claude Code / Codex / OpenHands have already done. Run an existing harness headless inside the workspace instead. Note harness/model coupling: Claude Code wants Claude models; OpenHands/OpenCode are the model-agnostic options if this must work across the heterogeneous roster.

**Architecture sketch:**
- *Rails = workspace control plane.* New `AgentWorkspace` model (agent user_id, Fly app/machine/volume IDs, region, state, last_used_at, image version) + provisioning service over Fly's Machines REST API. Lifecycle CRUD is short calls (hundreds of ms) — fine on Puma/Sidekiq; the no-blocking-IO-in-Rails concern applies to holding connections during *execution*, not lifecycle. Grant is fail-closed and admin-only (same posture as `external_tools`; never self-grantable).
- *Machine = managed bridge agent.* Image contains the harness, MCP wiring to `/mcp` with the agent's token, and a small daemon that pulls tasks and reports results.
- *Connectivity: the daemon dials out; nothing dials in.* Zero ingress on machines — no per-machine auth surface. Wake-on-task: Rails starts the stopped machine via Fly API; the daemon boots and pulls its task.
- *Task flow:* coding-shaped task routed at Rails dispatch (skips the Redis stream entirely) → machine started → daemon runs the harness against the workspace volume → the harness's Harmonic-side actions go through `/mcp` as normal (so `McpToolCallLog` captures them) → daemon reports progress steps → idle-stop after a quiet window.

**Agent-runner impact: almost none.** The runner keeps short loops and chat turns; the workspace runtime is a parallel surface of the same agent identity. Teaching the runner to orchestrate Fly machines (new API service, wake-dispatch-relay path, minutes-to-hours session semantics against its 30s timeouts and short-step concurrency model) buys little over the daemon-dials-out pattern — only worth revisiting if a unified dispatch/step pipeline becomes desirable. The one shared piece needed regardless: a step conduit for workspace sessions (same family as `/internal/agent-runner/tasks/:id/step`) so coding runs land in the `AgentSessionStep` timeline instead of being an opaque gap between "task started" and "PR appeared."

**Main challenges, ordered by expected pain:**
1. *The LLM gateway must become reachable from Fly* — the biggest infrastructure change hiding in the design. The harness must bill through llm-gateway (BalanceGate, ledger receipts), which is currently internal-Docker-network-only. Either public exposure with per-agent gateway keys + rate limiting (a new internet-facing billing chokepoint) or WireGuard peering between the Fly org network and the VM network (easy from Fly's side; new ops dependency). Security-critical surface either way.
2. *Pool-funding trust model needs an explicit extension.* Settled invariant: spending guarantee ⟺ internal runtime; external runtime gets no structural guarantee. A platform-operated machine is a third category: spending is still structurally capped by BalanceGate **iff the only LLM credential on the machine is a gateway key** — which is an egress-control and secrets-hygiene property, not a code property. Decide deliberately; don't let workspace agents inherit pool funding by default.
3. *Egress control is DIY.* Fly machines have open outbound and no per-machine egress allowlist; a prompt-injected agent with open egress can exfiltrate anything on its volume (MCP token, repo contents). Mitigations: an egress-proxy machine in the Fly private network that workspaces route through (allowlist: package registries, git host, gateway, `/mcp`), or in-image iptables (weaker). The largest genuinely-new engineering item.
4. *Durable credentials on persistent machines.* Departure from the runner's per-task ephemeral tokens: the workspace holds a long-lived agent MCP token and gateway key on disk. Needs rotation, revocation-on-suspicion (burn token, quarantine/wipe volume), and a deliberate decision about what else lives there — git deploy keys especially.
5. *Fleet operations.* Volumes are pinned to a physical host (no free migration); backup/GC policy, image-upgrade story (recreate machines preserving volumes), idle-stop tuning, wedged-workspace runbook. Not hard, but ongoing operational surface that doesn't exist today.
6. *Two-meter billing.* LLM tokens flow through the existing ledger; Fly compute is a separate org-level bill needing per-machine attribution — probably a flat "workspace" line-item charged to the funding pool (a mostly-stopped 1 GB machine is single-digit dollars/month) rather than per-second metering.
7. *Product design the infra can't answer.* What agents code on (Harmonic-hosted repos? GitHub org repos with deploy keys?), where results land (PRs? notes with diffs?), review-before-merge flow, and which agents/collectives qualify. These shape the image and grant model more than any technical choice.

**Staging:** (1) prototype — port the bridge-agent setup script to a Dockerfile, run one persona's workspace on Fly manually, gateway over WireGuard; proves image, bridge pattern, and billing path end-to-end. (2) Control plane — `AgentWorkspace`, provisioning service, fail-closed grant, admin UI, idle/wake lifecycle. (3) Dispatch + audit — task routing, daemon pull protocol, step reporting into the session timeline. (4) Hardening — egress proxy, token rotation, per-run budgets, compromise runbook; **gate on this before any non-operator-run agent gets a workspace.**

## Open questions

1. **SSRF/egress strategy for the runner** — application-level guard (custom undici lookup) vs network-level egress isolation (runner loses direct access to internal services it doesn't need)? The latter is stronger but is an infra change.
2. **Search provider** — Brave vs Tavily vs Exa vs self-hosted SearXNG; and since Harmonic is self-hostable, is `web_search` simply unavailable without a key, or does OSS deployment get a keyless default?
3. **Audit depth** — are `AgentSessionStep` rows sufficient for external calls, or do we mirror `McpToolCallLog` (per-call rows, verbatim URL/query, cost) via the internal step endpoint?
4. **Rate/cost limiting locus** — per-task caps in the runner + per-tenant aggregates where? (Runner Redis counters vs Rails accounting.)
5. **Grant authority defaults** — tenant toggle on or off for the primary tenant; principal-grantable from day one or sys-admin-gated first?
6. **`fetch_url` content processing** — raw text vs readability extraction vs markdown conversion; matters given the 4,000-char tool-result truncation in `AgentLoop`.
7. **Credential custody for stage 3** — encrypted in the Redis payload (existing pattern) vs fetched at task start via the HMAC internal API; and Rails-side storage (AR encryption setup needed either way).
8. **Chat mode** — do `chat_turn` tasks get external tools at the same time as task mode?
9. **Do external MCP clients ever get Harmonic-hosted tools?** (Option C as a product feature for Claude Desktop users, separate from internal-agent empowerment.)

## Key files

- `agent-runner/src/core/AgentContext.ts` — tool definitions + prompt prose
- `agent-runner/src/core/ActionParser.ts` — tool-name parsing / hallucination guard
- `agent-runner/src/services/AgentLoop.ts` — dispatch switch, per-task budgets
- `agent-runner/src/services/McpClient.ts` — generic `callTool` exists here (unexported)
- `agent-runner/src/core/StepBuilder.ts` — new `external_tool` step type
- `agent-runner/src/core/LeakageDetector.ts` — canary scan, extend to outbound args
- `app/services/capability_check.rb` — grant model (`external_tool_allowed?`, fail-closed)
- `app/services/agent_runner_dispatch_service.rb` — task payload (add `external_tools`)
- `app/controllers/internal/agent_runner_controller.rb` — step ingestion (audit rows, cost rollup)
- `docs/AGENT_RUNNER.md` — the async-IO rationale that shapes the execution-locus decision
