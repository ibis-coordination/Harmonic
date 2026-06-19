# Stage 2 — Agent representation via action context

> Depends on Stage 1 (the `context` block exists). Wires agents into the **already-existing** `RepresentationSession` mechanism by adding two context fields — `representation_session_id` and `identity.on_behalf_of` — so an agent can act on behalf of a human principal or a collective. No agent sessions required. Shared concepts in the [overview](action-context-overview.md).

## Premise: representation is already per-call and stateless

Humans already represent via the API by creating a `RepresentationSession` and sending `X-Representation-Session-ID` on each request; the server swaps `current_user` → `effective_user` for that request ([application_controller.rb], [representation_session.rb](app/models/representation_session.rb)). Agents reach the *same* mechanism by declaring `representation_session_id` in `context` per call. This needs nothing from Stage 3 — the per-call declaration is self-carrying, exactly like the header.

## What ships

When representing, the `context` carries two more fields:

```js
context: {
  "visibility": "shared",
  "identity": { "actor": "@agent-bob", "on_behalf_of": "@principal-alice" },
  "intention": "...",
  "representation_session_id": "def456"
}
```

- `representation_session_id` — **gate**: exists, active, and belongs to the calling agent (the agent is its `trustee_user`).
- `identity.on_behalf_of` — **gate**: matches the rep session's `effective_user`.
- When valid, the action runs with the `effective_user` swap, attributing the write to the principal/collective.

**All-or-nothing:** `representation_session_id` and `identity.on_behalf_of` appear together or not at all. One without the other rejects (`representation_incomplete`). Absent both = acting as self (Stage 1 behavior, unchanged).

## Grant flow (no model change)

`TrusteeGrant` already permits an `ai_agent` as `trustee_user` — only self-grants and `collective_identity` trustees are blocked ([trustee_grant.rb:173-189](app/models/trustee_grant.rb#L173-L189)). So a grant pointed **at** an agent is already valid and `can_represent?` honors it. Stage 2 builds the *flow*, not the model:

- Create a **pending** grant aimed at an agent: principal → agent, or collective → agent (the `effective_user = collective.identity_user` path, gated by collective membership).
- A way for the agent to **accept/activate** it. (The auto-created agent → parent grant is pre-accepted; principal → agent grants start pending.)

## Starting/ending representation

`start_representation` / `end_representation` are *already* agent-grantable capabilities. They are ordinary write actions performed **as self** — under Stage 1 they carry a self-`identity` `context` (no `representation_session_id` yet) — and `start_representation` returns the new `representation_session_id`. No special bootstrap exemption is needed (unlike Stage 3's `start_session`). Subsequent writes then include that id plus `on_behalf_of`.

Representation remains **singleton per user** (starting one requires no other active session for that actor) — an agent represents at most one principal/collective at a time.

## Error contract (Stage 2 additions)

| Code | When |
|---|---|
| `representation_unknown` | no such session |
| `representation_inactive` | session ended/expired |
| `representation_forbidden` | session not owned by this agent / no valid grant |
| `on_behalf_of_mismatch` | `on_behalf_of` ≠ rep session's effective user |
| `representation_incomplete` | exactly one of `representation_session_id` / `on_behalf_of` present |

## Recording

Audit row captures both the agent (`actor`) and the `effective_user` it acted as, plus the grant — so "what the agent did" and "whose authority it used" are both recoverable. Reuse `RepresentationSessionEvent` logging where it already fires.

## Discovery

Extend the `execute_action` schema + frontmatter + help docs with the two new fields and the all-or-nothing rule.

## Tasks (red-green TDD)

1. Accept `representation_session_id` + `identity.on_behalf_of`; enforce all-or-nothing.
2. Validate the rep session (active, owned) + `on_behalf_of` vs. `effective_user`.
3. Apply the `effective_user` swap for the action (reuse the existing representation path).
4. Grant accept/activate flow for grants aimed at an agent (principal → agent, collective → agent).
5. Wire `start_representation` / `end_representation` for agents; return/close the session id.
6. Audit recording (actor + effective user + grant).
7. Schema + frontmatter + help updates.

## Done when

- An agent with a valid grant can `start_representation`, receive an id, thread it + `on_behalf_of`, and have writes attributed to the principal/collective.
- Foreign/inactive/incomplete representation declarations reject with the right code.
- Acting-as-self (Stage 1) is unchanged.

## Open (Stage 2)

- Whether collective → agent representation (acting as a `collective_identity`) ships in Stage 2 or splits to its own step.
- Whether the cross-service (agent-runner/system-prompt) update for representation rides Stage 2 or waits until agents actually need to represent.
