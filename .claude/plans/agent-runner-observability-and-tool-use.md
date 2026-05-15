# Agent-runner: observability and tool-use reliability

Two related concerns surfaced while debugging Trio on `trinity-large-thinking`:

## Concern 1 — `think` steps are often opaque

`AgentLoop` records the LLM's `response.content` as the think step's
`response_preview`. When the model emits only a tool call (no
accompanying text), the field is empty and the timeline reads as if the
model did nothing. For reasoning-capable models (Claude extended
thinking, OpenAI o-series, Arcee `trinity-large-thinking`) the actual
reasoning lives in a separate `reasoning` / `thinking` field that the
agent-runner doesn't currently capture at all.

**Improvements to consider:**
- Capture tool-call summary in the think step when `content` is empty
  (e.g., `"called navigate(/collectives/chariot)"` or compact JSON of
  the tool name + args). Closes the visual gap in the timeline without
  any LLM changes.
- Capture model `reasoning` / `thinking` separately when the LLM
  response carries it. Requires `LLMClient` to surface those fields and
  `StepBuilder.thinkStep` to accept and persist them. Schema change on
  `agent_session_steps.detail` is minor (it's already JSON).
- Surface tool-call args in the timeline UI for `navigate` and
  `execute` steps — makes the cause/effect between the empty think and
  the resulting action obvious.

## Concern 2 — Weaker models don't call tools correctly

`trinity-large-thinking` completed a "mention" task in 6 steps without
ever invoking `post_comment` — it stuffed the answer into the `done`
tool's message and stopped. Claude under the same prompt takes 14–18
steps and posts the answer as a comment via the right tool. The user
sees nothing because `done.message` isn't surfaced anywhere — it just
records on the task run.

This is a model-behavior problem on top of an agent-runner gap:

**Improvements to consider:**
- **Stronger tool-use guardrails in the agent system prompt.** Explicit
  language like *"`done` is not a way to communicate with users; if
  your response is intended for a user it must be posted via the
  appropriate action (e.g., `post_comment`)"*. Cheap first move; helps
  every model.
- **Post-completion check on the agent-runner side.** When a task
  triggered by a user-facing event (e.g., a mention) completes without
  having invoked an outward-communication tool, treat it as a failure
  (or surface a "did nothing visible" warning) rather than silently
  recording it as a success.
- **Fallback / per-task model selection.** Allow an agent or a task to
  declare a fallback model so that thinking-only / smaller models can
  hand off to a stronger one when their first attempt doesn't include
  the expected tool call. Bigger change; depends on cost tradeoffs.
- **Tool-use evaluation harness.** A small fixture set ("mention,
  navigate, post comment", "decision created, post analysis", etc.)
  that runs across configured models and reports which ones complete
  the loop correctly. Useful before flipping the default model.

## Out of scope (for now)

- Sentry capture for agent-runner failures (separate observability
  concern; tracked in the Trio-monitoring discussion).
- Per-collective / per-agent failure notifications.
- Cost / token dashboards beyond what's already on the agent run page.

## Suggested order

1. Sprint A — observability (Concern 1):
   - Tool-call summary in empty think steps (cheap)
   - Capture `reasoning` field when present (depends on LiteLLM passthrough)
   - Surface tool-call args in the timeline UI
2. Sprint B — tool-use reliability (Concern 2):
   - Strengthen system prompt for tool-use discipline
   - Post-completion "did nothing visible" warning
   - Optional model fallback / harness, as cost-benefit warrants

Both sprints stand alone; either can be done first depending on which
pain is sharper.
