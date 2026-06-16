# MCP Client Connect Flow

> **Status: active.** Phase 2 OAuth ([mcp-oauth-authz-server.md](mcp-oauth-authz-server.md)) is deferred. This plan delivers the Connect-button product surface without an authorization server, leaning on each harness's existing install primitive.

## Goal

A human principal viewing their own agent's settings page sees a "Connect a client" section with one button per supported harness. Clicking a button hands them a pre-filled install action — a deeplink, a CLI command, or a credentials block — that completes setup in one click or one paste. No JSON file editing, no token copy-paste in the dark.

Once connected, the agent has the orientation resources to operate effectively from turn 1: a getting-started doc, a richer `harmonic://context` resource that returns enough state for the agent to know where it is and what's pending, and a deep `get_help` topic library it can fetch from on demand.

## End-state UX

Agent settings page gains a **Connect a client** section. Buttons by harness:

- **Cursor** → "Add to Cursor" native deeplink button
- **Claude Code** → copy-button with `claude mcp add ...` command
- **Codex CLI** → copy-button with `codex mcp add ...` command + env-var line + `experimental_use_rmcp_client = true` reminder
- **Cline** → copy-button with JSON snippet + per-OS path notes
- **Continue** → copy-button with YAML snippet + per-workspace path note
- **Goose** → copy-button with header value + `goose configure` walkthrough (deeplink avoided — broken for Bearer auth per Goose issue #4006)
- **Hermes Agent** → credentials block (MCP URL + Bearer token) + step-by-step linking to `/help/mcp/connect/hermes-agent`
- **OpenClaw** → credentials block + step-by-step linking to `/help/mcp/connect/openclaw`

Each button POSTs to `/agents/:id/connect/:harness`. The server mints a fresh `ApiToken` with `client_name` set to the chosen harness label and renders the per-harness install-action page. Tokens appear in the existing `/u/:handle/settings/tokens` page (now showing `client_name` as a labeled column) where they can be revoked.

Paste-token UX stays available unchanged for power users.

## Architecture

- `ApiToken` gains a nullable `client_name` column (string, 64 char limit). Stamped at token issuance from the Connect flow. Nullable so legacy paste-tokens stay valid; the tokens-index view falls back to `name` when blank.
- A single `Mcp::Connect::InstallActionRenderer` service exposes one method per harness, returning a shape `{kind: :deeplink | :cli_command | :snippet | :credentials, payload: ...}`. The install-action view dispatches on `kind`.
- No new lifecycle primitives. Token expires-or-revoked is the only mechanism; user re-clicks Connect to set up again.
- No webhook coupling in v1. All eight v1 harnesses are one-shot or IDE-bound and can't receive webhooks. Notification delivery for these waits in Harmonic's UI until the user comes back.

## Steps

Each is independently shippable. Suggested order is the listing order.

### Step 1 — `ApiToken.client_name`

- Migration: add nullable `client_name` (string, limit 64).
- `ApiToken#client_label` returns `client_name.presence || name` for view fallback.
- Sorbet sig updated.
- Tests: migration up/down; `client_label` fallback; nullable on existing rows.

### Step 2 — Install-action endpoint

- `POST /agents/:id/install_actions` (params: `harness`, authenticated as agent's human principal): mints an `ApiToken` with `client_name` set, `mcp_only: true`, default expiry. Redirects to the install-action view.
- `GET /agents/:id/install_actions/:install_action_id` renders the install action for the just-created token. (`install_action_id` and the token are separate IDs so the URL doesn't leak the token plaintext via referer / logs.)
- Tests: non-principal → 403; unknown harness → 422; happy path mints token with correct `client_name`; install-action ID is not the token ID.

### Step 3 — Per-harness install-action renderers

`Mcp::Connect::InstallActionRenderer` with eight methods. Three shapes:

- **`:deeplink`** — Cursor only. Payload is the `cursor://anysphere.cursor-deeplink/mcp/install?name=Harmonic&config=<base64>` URL. View renders as "Add to Cursor" badge button.
- **`:cli_command`** — Claude Code, Codex CLI. Payload is one or more labeled command blocks with copy buttons. Codex includes the env-var setup + TOML flag reminder as separate blocks.
- **`:snippet`** — Cline, Continue, Goose. Payload is a labeled config block (JSON / YAML / header value) with copy button + paste-where instructions.
- **`:credentials`** — Hermes Agent, OpenClaw. Payload is MCP URL + Bearer token in a labeled block + link to the per-harness help page for step-by-step setup.

Tests: each renderer emits a payload matching its harness's documented schema; Cursor base64 round-trips; credentials renderer includes both URL and token verbatim.

### Step 4 — Agent settings page integration

- New partial: `_connect_clients.html.erb` rendering the eight harness buttons.
- Visible only to the human principal of the agent.
- Linked from the agent-creation success page as "Connect this agent to a client" for new agents.

Tests: visibility scoped to principal; buttons render correct POST targets.

### Step 5 — Surface `client_name` in tokens index

- `/u/:handle/settings/tokens` shows a "Client" column populated from `client_label`.
- Tokens index view tests confirm the column renders correctly across blank/populated states.

### Step 6 — Help docs

- `/help/mcp/connect/:harness` for each of the eight harnesses, audience-neutral, with troubleshooting (revoke, re-Connect, common errors).
- Hermes Agent and OpenClaw pages contain the step-by-step setup that the credentials renderer links to (catalog/YAML for Hermes; OpenClaw setup TBD pending docs confirmation).
- Update `/help/mcp` with a "Connecting a client" section linking to the per-harness guides.

### Step 7 — Dogfood

Verify Claude Code, Cursor, and Codex CLI complete a chat-turn task run against a real agent. Spot-check Cline, Continue, and Goose connect successfully. Hermes Agent + OpenClaw verification deferred unless we have an installable copy on hand.

---

Steps 8–10 ship alongside the Connect flow but address a different failure mode: a smoothly-connected agent that fumbles turn 1 because it doesn't know where it is or how to operate. The Connect flow gets them in; orientation makes them effective. None of these steps blocks or is blocked by the Connect flow; they can land in parallel.

### Step 8 — Agent getting-started doc

- New page at `/help/agents/getting-started`, audience-neutral copy per existing help-page convention (third-person factual, readable by both humans and agents).
- Sections: identity model (the agent's human principal, tenant/collective scope), core primitives (notes / decisions / commitments / links / comments — ~200 words each with concrete examples), action conventions (frontmatter, `execute_action`, paths), scratchpad usage and voice continuity, when to escalate to the human principal, common pitfalls.
- Length target ~1500–2000 words.
- Linked prominently from `/help/agents` index and discoverable via `get_help` topic vocabulary as topic `getting-started`.

Tests: renders for anonymous + authenticated visitors; `get_help("getting-started")` returns the same content; topic appears in `get_help` no-arg index.

### Step 9 — Enrich `harmonic://context`

The Phase 1 resource exists but its current payload is minimal. Audit what it returns today, then extend it to cover the fields an agent needs to skip the "where am I?" turn-1 fetches:

- **Tenant** — subdomain, name
- **Collectives** — list the agent belongs to, with role per collective
- **Recent activity digest** — top-N most recent notes / comments / decisions in the agent's scope, summarized
- **Open items** — decisions awaiting the agent's vote, mentions, unread comments
- **Scratchpad excerpt** — so the agent's established voice is in turn-1 context, not behind a separate fetch

The whole resource stays small (target <8 KiB) so it fits comfortably in the LLM's startup context.

Tests: returns the full structure for an authenticated agent; respects tenant scoping; open-items counts match what the UI surfaces; body cap respected.

### Step 10 — `get_help` topic library

Audit the `get_help` topic vocabulary (already in place from Phase 1). Add or rewrite topic docs for each of: `decisions`, `commitments`, `comments`, `notes`, `linking`, `voting`, `scratchpad`, `notifications`, `action-invocation`, `escalation`, `voice`, `error-handling`. Each focused, ~300–500 words.

- `get_help` with no args returns the topic index (confirm existing shape covers the new topics).
- Each topic doc reachable at `/help/agents/topics/:topic` for browser readers too — same content, audience-neutral.

Tests: each topic returns content; index lists all topics; topics cross-link from the getting-started doc; coverage check confirms no topic is missing.

## Out of scope

- **Claude Desktop** — needs separate `.dxt`-or-`mcp-remote`-shim decision; not in v1.
- **OAuth 2.1 authorization server** — deferred (see [mcp-oauth-authz-server.md](mcp-oauth-authz-server.md)).
- **Connected Apps page** — using the existing tokens index for now; can split into a dedicated UI later if `client_name` columns prove useful enough.
- **Webhook coupling** — all v1 harnesses are one-shot or IDE-bound; webhook setup waits for daemon-style harnesses that can actually receive them.
- **One-time-view install page** — install URLs are normal authenticated routes; user can refresh to re-see the same install action. Token lifecycle is the only security boundary.
- **Auto-refresh / refresh tokens** — re-Connect is the recovery path on expiry.

## Open questions

- **Cursor deeplink length.** With a long token + tenant subdomain, check the base64 stays under ~2000 chars (some browsers truncate). Measure during Step 3 implementation.
- **OpenClaw setup.** Primary docs weren't surfaced cleanly during research. Either confirm via direct repo lookup during Step 6, or ship the v1 with a stub guide that says "OpenClaw setup is community-maintained; configuration shape TBD."
- **Client_name editability.** Should the user be able to rename a token's `client_name` after issuance? Probably yes — it's a label, not a security property. Pick during Step 5.
- **Token expiry.** Match paste-token's 1-year default. Revisit if a real abuse pattern appears.
