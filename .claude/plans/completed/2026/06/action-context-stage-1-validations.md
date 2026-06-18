# Stage 1 — Action context validations

> Independently shippable; depends on nothing. Adds the required `context` block to agent write actions with three pure validations — `visibility`, `identity`, `intention` — and records the block to the audit trail. No sessions, no representation. Shared concepts in the [overview](action-context-overview.md).

## What ships

Agent write actions require a `context`:

```js
context: {
  "visibility": "public" | "private" | "shared",
  "identity": { "actor": "@handle" },
  "intention": "free-text description of what I'm doing"
}
```

- `visibility` — **gate**: must match the tier of the space the action actually lands in.
- `identity.actor` — **gate**: must equal the calling agent's own handle.
- `intention` — **annotation**: must be present and non-empty; content is never validated, only recorded.

Fields belonging to later stages (`representation_session_id`, `identity.on_behalf_of`, `agent_session_id`) are not part of Stage 1; if sent, they're ignored (forward-compatible), not validated.

## Caller scoping

Required only for agent callers (`CapabilityCheck.restricted_user?` / `ai_agent?`, [capability_check.rb:269](app/services/capability_check.rb#L269)). Human browser/API/markdown-UI writes are unaffected and never send `context`.

## Which actions require `context`

**Every action does.** There is no high-stakes/low-stakes distinction and no per-action list. `context` is a required parameter of `execute_action` itself — if it runs through `execute_action`, it carries `context`. This is also how the agent *knows*: the MCP tool schema marks the field required, so the requirement is surfaced (and client-side enforced) before any call is sent, rather than memorized.

The only context-free calls are the separate **read tools** (`fetch_page`, `search`, `get_help`) — they aren't actions and don't go through `execute_action`. Actions reached via `execute_action` that happen to be low-stakes (`mark_read`, `dismiss`, `send_heartbeat`, `update_scratchpad`, `confirm_read`) require `context` like any other; their declared `visibility` is simply whatever space their path resolves to (e.g. `update_scratchpad` → `private`).

## Visibility resolution

Classify by **audience** — who can see the result — from ground truth (the resolved resource/space, *not* a string parse of `path`). Precedence-ordered:

1. **only the acting agent** sees it → `private` — the agent's own workspace content, its `whoami` scratchpad, its own notifications (`dismiss`/`mark_read`).
2. else **public** (the tenant's main collective) → `public`.
3. else → `shared` — invite-only collectives, chat, relational/account writes (trustee grants, etc.).

Compare to the declared `visibility`; mismatch rejects. Because resolution is ground-truth, the gate can't drift from where the write actually goes. Note the tier is a property of the action's **audience**, not strictly its collective — agent-scoped surfaces (`whoami`, own notifications) are `private` even though they don't route through a workspace collective.

**Enforcement point:** validate *before* the mutating step — the cleanest hook is in the action filter chain once the target resource/space is resolved but before the action body runs.

## Identity

`identity` is always `{ actor: "@handle" }` in Stage 1. `actor` must equal the calling agent's handle (the token's user). Mismatch rejects. (`on_behalf_of` arrives in Stage 2.)

## Intention

Presence-required: a missing or empty `intention` rejects (`intention_missing`). Content is never inspected — its value is forcing the agent to articulate, and the audit record.

## Recording

Store the full `context` **verbatim** on `McpToolCallLog` (it's audit metadata, not the `params` payload that today's redaction shape-summarizes).

- **Open:** non-MCP agent writes (direct REST/markdown-UI POSTs with an agent bearer token) bypass `McpToolCallLog`. Decide in implementation planning whether Stage 1 (a) enforces on those too — needing a recording sink (the existing resource-attribution row, or a small log) — or (b) scopes to MCP `execute_action` only and treats direct-POST coverage as a fast-follow. Note the bypass risk either way.

## Error contract (Stage 1 subset)

`422 { error, expected, got }`:

| Code | When |
|---|---|
| `context_missing` | required but absent (agent caller, write action) |
| `visibility_missing` / `visibility_mismatch` | absent / declared tier ≠ resolved tier (`expected`=resolved, `got`=declared) |
| `identity_missing` / `identity_mismatch` | absent / `actor` ≠ caller handle |
| `intention_missing` | absent or empty |

## Discovery

The agent learns the requirement from the tool definition, not from documentation it has to find:

- `execute_action` MCP tool schema: declare `context` a **required** parameter (so omitting it is a schema-level error, not just a server rejection), and document the `visibility` enum, `identity` shape, and `intention`.
- Update `get_help` / help docs (written third-person — agents read them) to describe the `context` convention.

## Cross-service (critical — unflagged strict)

No kill switch. The **agent-runner** and the internal agent **system prompt** must send a valid `context` (visibility/identity/intention) in the *same release*, or every internal agent breaks on deploy. External MCP clients also break — communicate the change. Ship Rails + agent-runner together.

## Tasks (red-green TDD)

1. Parse + presence-validate `context` for agent write actions; reject `context_missing`.
2. Visibility resolver (resolved collective → tier) + `visibility` gate.
3. `identity.actor` gate vs. token user.
4. `intention` presence gate.
5. Verbatim recording on `McpToolCallLog`.
6. Structured `422` error responses with codes.
7. MCP schema + frontmatter + help-doc updates.
8. **agent-runner + system prompt**: emit `context` on every write (cross-repo).

## Done when

- An agent MCP write with no `context` → `context_missing`.
- Mismatched `visibility` or `identity` → rejected with the right code + `expected`/`got`.
- `intention` recorded; missing → `intention_missing`.
- Human callers entirely unaffected.
- agent-runner emits `context`; internal agents pass end-to-end.

## Open (Stage 1)

- Direct (non-MCP) agent-POST coverage + recording sink (above).
- Mechanical (not a design question): build the audience map for non-collective actions per the rule — agent-only → `private` (`update_scratchpad`, own notifications), relational → `shared` (`create_trustee_grant`, etc.).
