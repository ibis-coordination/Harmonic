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

---

## Notes from initial exploration (captured before compaction)

### What the savedPath replay actually does

In **chat mode only**, `AgentLoop` replays the chat session's saved
`current_path` right after the initial `/whoami` navigation
(`agent-runner/src/services/AgentLoop.ts` ~line 250). I initially
misread this as a wasted step (it triggers even when the LLM is
unreachable) and tried to delete it. It's load-bearing for two reasons:

1. **Action validity is page-scoped.** `executeAction` rejects any
   action name not in `currentActions`, and `currentActions` is set by
   `navigate`. Turn 1 navigates to a note; turn 2 says "add a comment";
   without the replay turn 2 is back at `/` with the wrong action set.
2. **Chat-history rehydration drops tool calls.** Only user/assistant
   text crosses turn boundaries. The agent has no memory of pages it
   visited previously, so the replay re-fetches that content into the
   LLM's message context.

Task mode (the path Trio takes for `@trio` mentions) does NOT replay —
it always starts at `/whoami` and lets the LLM drive from there. So
Sprint A timeline work should treat the chat-mode "second navigate" as
mandatory infrastructure, not LLM-spent steps. A future task-mode
multi-turn pattern would need similar state.

The replay is now annotated in code with both reasons.

### What the empty `think` step actually means

Sprint A Concern 1 was framed around "think steps are opaque." Concrete
shapes observed:

- `response_preview` empty (often just `"\n"`) → LLM emitted only tool
  calls, no text content. Normal behavior for many models. The tool
  call surfaces as the *next* step (navigate/execute).
- `response_preview` non-empty → LLM emitted text alongside (or instead
  of) tool calls. The `done` tool's message goes here too.

Reasoning models (`trinity-large-thinking`, Claude extended thinking,
OpenAI o-series) put their actual reasoning in a separate
`reasoning` / `thinking` response field that `LLMClient.chat` doesn't
currently parse. That's the real "opaque think" — and it's where most
of the visibility win lives. Sprint A's "capture reasoning" item is
the highest-value piece, not "tool-call summary in empty think."

### Tool-use failure pattern observed

Trio on `trinity-large-thinking` completed a mention-triggered task in
6 steps without ever calling `post_comment`. It navigated correctly,
read the note, then emitted its answer as the message argument to the
`done` tool and stopped. The user saw nothing because `done.message`
isn't surfaced outside the task run record. Claude on the same prompt
took 14–18 steps and used the right tool.

Worth probing whether this is a prompt-clarity issue (the system prompt
doesn't explicitly say "done isn't a way to reach users; you must call
post_comment") or a model capability issue. Sprint B's stronger
guardrails are the cheap first move. A "completed without invoking an
outward-communication tool" warning would catch this regression at
run time and turn an invisible failure into a visible one.

### Model configuration plumbing (current state)

- `default` alias in `config/litellm_config.yaml` points at Arcee's
  `trinity-large-thinking` via the Arcee API (requires `ARCEE_API_KEY`).
- `trinity-large-thinking-free` alias routes the same model through
  OpenRouter's free tier (requires `OPENROUTER_API_KEY`). LiteLLM
  provider prefix is `openrouter/`, not `openai/`.
- New trios get their model from `TRIO_DEFAULT_MODEL` env var (recently
  added in `TrioSeeder.default_model`). Unset = no `model` key in
  `agent_configuration`, agent-runner falls back to the `default`
  alias.
- Per-agent override: any agent's owner can set `model` on the agent
  via its settings page. `TrioSeeder.refresh` does NOT overwrite an
  existing model value, so manual overrides persist.

### Dev environment gotchas

- The agent-runner container is **built from source** (no volume
  mount). To pick up local changes:
  `docker compose --profile llm build agent-runner && docker compose --profile llm up -d agent-runner`.
- The LiteLLM container is volume-mounted for the config file, but
  env vars are only loaded at container CREATE time. To pick up
  `.env` changes use `docker compose --profile llm up -d --force-recreate litellm`
  (not `restart`).

### What's committed on this branch so far

- `aa985e0` — savedPath replay documentation + tests (captured the
  insight above so the next reviewer doesn't repeat my mistake).
- `39d5256` — `TRIO_DEFAULT_MODEL` env var support; `.env.example`
  documentation refresh; OpenRouter trinity-large-thinking-free alias
  in `litellm_config.yaml`.

Neither is in the Sprint A/B scope yet — both are groundwork.
