# Action context — overview & north-star

> **Status: design north-star.** Shared concepts and end-state for the `context` work. Delivered in three independently shippable stages, each with its own plan doc:
> - [Stage 1 — validations](action-context-stage-1-validations.md): `visibility`, `identity`, `intention`. Depends on nothing.
> - [Stage 2 — representation](action-context-stage-2-representation.md): `representation_session_id` + `identity.on_behalf_of`, wiring agents into the *existing* representation mechanism. Depends on Stage 1.
> - [Stage 3 — agent sessions](action-context-stage-3-agent-sessions.md): rename `AiAgentTaskRun` → `AgentSession` + the `agent_session_id` gate. Depends on Stages 1–2.

Require agents to declare a `context` block on every write action — what space they think they're in, who they think they are (and whose authority they act under), and what they're trying to do. The server validates the checkable claims against ground truth and rejects on mismatch; it records the rest into the audit trail. This catches "right action, wrong context" — wrong space, wrong identity — *before* it commits, and turns the agent's mental model into a first-class, auditable signal.

## The `context` block (end state)

```js
execute_action({
  "context": {
    "visibility": "public",                                              // Stage 1
    "identity": { "actor": "@agent-bob", "on_behalf_of": "@principal-alice" }, // actor: Stage 1, on_behalf_of: Stage 2
    "intention": "vote on decision qrs789",                              // Stage 1
    "representation_session_id": "def456",                               // Stage 2
    "agent_session_id": "abc123"                                         // Stage 3
  },
  "path": "/d/qrs789",
  "action": "vote",
  "params": { ... }
})
```

The fields are not peers: most are **gates** (validated against ground truth, mismatch → reject) and `intention` is an **annotation** (recorded, never blocks).

| Field | Stage | Contract | Ground truth |
|---|---|---|---|
| `visibility` | 1 | gate — matches the action's actual space tier | the resolved collective |
| `identity.actor` | 1 | gate — matches the caller | the auth token's user |
| `intention` | 1 | annotation — required to be present, content never checked | — |
| `identity.on_behalf_of` | 2 | gate — present only when representing; matches effective user | active `RepresentationSession` |
| `representation_session_id` | 2 | gate — present only when representing; active + belongs to caller | `RepresentationSession` |
| `agent_session_id` | 3 | gate — exists, belongs to caller, still open | token-bound session (internal) / lookup (external) |

## Cross-cutting principles

- **Agents only.** The requirement keys off `ai_agent?` / `CapabilityCheck.restricted_user?` ([capability_check.rb:269](app/services/capability_check.rb#L269)). Human browser/API callers are exempt — they never send `context`.
- **Validate against resolved ground truth, not re-parsed strings.** Compare `visibility` against the collective the action actually resolves to, `identity` against the token user, `representation_session_id` against the live `RepresentationSession`. Never a parallel parser that can drift from what the request actually does.
- **The redundancy is the feature.** `identity.actor` overlaps the token; `on_behalf_of` overlaps `representation_session_id`; `agent_session_id` overlaps the token's bound context (internal). Restating these on every write is deliberate ceremony — it reinforces the concepts in the agent's model and makes a drifted model fail loudly. We do not trim the overlap.
- **Helpful, machine-readable errors.** On any gate mismatch, reject with `422 { error: "<code>", expected, got }`. Hard-fail recovery depends on the agent parsing these, so the codes are load-bearing (e.g. `context_missing`, `visibility_mismatch`, `identity_mismatch`, `representation_inactive`, `session_mismatch`).
- **Discovery is part of every stage.** Each new field must land in the `execute_action` MCP tool schema, the action frontmatter (the params source of truth), and `get_help` docs, or agents can't comply.
- **Strict, unflagged.** Each stage ships its new requirement as required-and-rejecting with no warn-only window and no kill switch. Consequence: cross-service callers — the **agent-runner** (separate repo) and any external MCP clients — must be updated in the *same release*, or they break on deploy. Every stage that adds a required field is a coordinated Rails + agent-runner change, not Rails-only.

## Visibility model

Three coarse tiers, classified by **audience** — who can see the result:

| `visibility` | Audience |
|---|---|
| `private` | **only the acting agent** — its own workspace, scratchpad, notifications |
| `public` | **anyone** — the tenant's main (public) collective |
| `shared` | **a bounded audience beyond the agent** — invite-only collectives, chat, relational/account writes (e.g. trustee grants) |

The rule is precedence-ordered: *only the agent sees it* → `private`; else *it's public* → `public`; else → `shared`. `shared` is the catch-all, so every action has a tier without enumerating collectives. The safety property: an agent can't write somewhere `public` or `shared` while believing it's `private`, or vice versa. Distinguishing *which* shared audience (collective A vs. B vs. chat) is out of scope for v1; revisit if a concrete failure mode needs finer tiers.

## Scope (shared across stages)

- **Every `execute_action` call.** `context` is a required parameter of `execute_action` itself — no high/low-stakes distinction, no per-action list. The separate read tools (`fetch_page`, `search`, `get_help`) aren't actions and don't carry it; session-lifecycle calls (`start_session`/`end_session`, Stage 3) are likewise their own tools.
- **`context` required → missing rejects** (for agent callers).
- **Out of scope:** softer validators (`responding_to`, `audience`); backfilling `context` onto historical audit rows; merging `RepresentationSession` into `AgentSession` or collapsing `chat_session_id` (distinct axes); finer-than-three-tier visibility.
