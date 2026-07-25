# Agent Chat UX Improvements

## Goal

Improve the chat experience for AI agents — more honest status indicators, better agent behavior at step limits, and persistent activity context for humans.

## Problems

1. **"Thinking..." is dishonest.** The initial phase is task pickup and preflight, not thinking. Even during LLM inference, "thinking" anthropomorphizes in a way we'd rather avoid.
2. **Static text indicator.** The current indicator is italic text in a bubble. There's no animation, so it's easy to miss or mistake for a stale message.
3. **Activity context disappears.** When the agent sends a response, the activity indicator (navigate, execute) vanishes. The human loses context about what the agent actually did.
4. **Step limit kills the response.** If an internal agent hits its max step limit during a chat turn, it may never send a response message. The human sees nothing.
5. **No link to task run.** Humans can't easily see what the agent did during a turn — they'd have to navigate to the agent's task run page manually.

## Plan

### Phase 1: Replace "Thinking..." with animated indicator
- Replace the text-based indicator with an animated visual (e.g., pulsing dots, spinner, subtle wave)
- No "Thinking..." text — just the animation in a bubble attributed to the agent
- When activity events arrive (navigate, execute), show them as brief text under the animation
- CSS-only animation preferred (no JS animation loops)
- Only show for internal agents; external agents get no indicator on send

### Phase 2: Persistent activity summary with task run link
- When the agent's turn completes, replace the animated indicator with a compact activity summary
- The summary becomes a clickable link to the task run detail page (`/ai-agents/:handle/runs/:id`)
- Only shown to authorized users (agent owner / admin)
- Example: "Browsed 3 pages, took 2 actions" → links to task run
- This gives humans permanent context about what happened between their message and the agent's reply

### Phase 3: Guaranteed response at step limit
- When an internal agent approaches its max step limit during a chat turn, the agent-runner should reserve the final step for sending a response message
- The agent should always be able to say something — even if it's "I ran out of steps before finishing. Here's what I did so far: ..."
- This requires changes in the agent-runner's step loop to detect proximity to the limit and force a message step

### Phase 4: Better agent context on chat turns
- Give the agent better context at the start of a chat turn:
  - Recent conversation history (already done)
  - Current navigation state (already done via current_state)
  - What the human is likely expecting (e.g., if the human asked a question, the agent should prioritize answering)
- Consider a lightweight system prompt addition for chat mode that emphasizes conversational responsiveness

## Design Constraints

- Keep it minimal — this is a productivity tool, not a consumer chat app
- Animations should be subtle and not distracting
- Must work with the existing Stimulus controller architecture
- Activity links should degrade gracefully (no link if user lacks permission to view the task run)
