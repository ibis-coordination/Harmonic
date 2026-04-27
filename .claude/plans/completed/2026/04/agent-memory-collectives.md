# Agent Memory via Private Workspaces

## Context

This plan builds on top of the [Private Workspaces](private-workspaces.md) feature. Once every agent has a private workspace (a personal collective), we teach agents to use it as persistent memory — storing observations, learnings, and reasoning as Notes, Decisions, and Commitments.

The private workspace plan handles all the infrastructure: creation, filtering, billing exemption, heartbeat exemption, archival cascade. This plan focuses on the agent-specific layer: what goes in `/whoami`, how the system prompt teaches memory usage, and how the scratchpad relates to the workspace.

## Prerequisites

- Private Workspaces feature is implemented and deployed
- Every AI agent has a `private_workspace` via `User#private_workspace`

## Plan

### Step 1: Replace "Your Workspace" with "Your Memory" for agents on `/whoami`

**File:** [app/views/whoami/index.md.erb](app/views/whoami/index.md.erb)

The private workspaces plan adds a generic "Your Workspace" section for all users. For agents, replace it with richer memory-specific guidance. The section should use a conditional:

```erb
<% if !@current_representation_session && (workspace = @current_user.private_workspace) %>
<% if @current_user.ai_agent? %>
## Your Memory

Your private workspace is [<%= workspace.name %>](<%= workspace.path %>).
Use it to store persistent knowledge across tasks and conversations:

- **Create notes** to record observations, user preferences, learnings, and context you want to remember
- **Pin notes** that contain your most important reference material
- **Search** your workspace (`<%= workspace.path %>/search?q=...`) to retrieve past memories before starting a task
- **Link notes** to build associative connections between related memories
- **Update existing notes** when your understanding evolves — don't duplicate, refine

This workspace is completely private to you. If someone asks about your memories, you can share relevant information in conversation.
<% else %>
## Your Workspace

[<%= workspace.name %>](<%= workspace.path %>) — your private workspace for personal notes and drafts.
<% end %>
<% end %>
```

This means the private workspaces plan should add the `if/else` structure, and this plan just provides the agent branch content.

### Step 2: Add memory collective concept to agent-runner system prompt

**File:** [agent-runner/src/core/AgentContext.ts](agent-runner/src/core/AgentContext.ts)

Add one line to `HARMONIC_CONCEPTS` (line 138, before `Useful paths:`):

```
- **Private Workspace** — Your personal workspace for persistent memory (see /whoami for path). Create Notes to record learnings, Search to retrieve them, Links to connect related memories.
```

Add the workspace path to the `Useful paths:` line:

```
Useful paths: / (home), /whoami (your context), /collectives/{handle} (collective home), your workspace (see /whoami)
```

### Step 3: Update chat system prompt to encourage memory use

**File:** [agent-runner/src/core/AgentContext.ts](agent-runner/src/core/AgentContext.ts)

In `CHAT_BEHAVIOR` (line 182), add a line about memory:

```
- Before responding to complex or repeated topics, consider searching your private workspace for relevant past learnings
- After learning something important about a user or topic, consider saving it as a note in your workspace
```

### Step 4: Scratchpad coexistence strategy

**No code changes.** The scratchpad continues to work as-is — it's a fast, cheap, end-of-task memory update. The private workspace is complementary:

| | Scratchpad | Private Workspace |
|---|---|---|
| When written | End of every task (automatic) | During tasks (agent chooses) |
| Format | Flat text, 10KB max | Structured notes, unlimited |
| Searchable | No (injected in full) | Yes (agent can search) |
| Linkable | No | Yes (links between notes) |
| Inspectable by parent | Only via agent config | Not directly (parent asks agent) |
| Cost | 1 LLM call per task | Navigate + execute per note |

The agent uses the scratchpad for quick, volatile working memory ("what I was just doing") and the workspace for durable, organized knowledge ("what I've learned over time").

**Future consideration:** Once agents are reliably using their workspaces, we could replace the scratchpad update step with the agent creating/updating a pinned "Working Notes" note in its workspace. But this is not part of this plan.

### Step 5: Tests

- **Whoami**: agent with private workspace sees "Your Memory" section
- **Whoami**: human with private workspace does NOT see "Your Memory" section
- **Agent-runner**: system prompt includes private workspace concept (unit test on `HARMONIC_CONCEPTS` string content)

## Files to modify

| File | Change |
|------|--------|
| `app/views/whoami/index.md.erb` | Add "Your Memory" section for agents |
| `agent-runner/src/core/AgentContext.ts` | Add workspace concept + chat memory guidance |

## Verification

1. Run whoami controller tests
2. Run agent-runner tests: `cd agent-runner && npm test`
3. Manual: dispatch a task to an agent and check that `/whoami` includes "Your Memory" section in the agent's step log
4. Manual: start a chat with an agent, ask it to remember something — observe whether it navigates to its workspace to create a note
