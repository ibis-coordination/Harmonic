# In-App Documentation & Agent System Prompt Redesign

## Context

Harmonic has no real in-app documentation. The `/help` page is a placeholder. The agent system prompt ([AgentContext.ts](agent-runner/src/core/AgentContext.ts)) tries to compensate by cramming domain knowledge into a sparse glossary, but this serves neither humans nor agents well.

This plan takes a layered approach:

1. **In-app docs** (`/help/*`) — comprehensive help pages that explain Harmonic concepts for both humans and agents. These are the source of truth.
2. **Agent system prompt** — a concise operating guide that teaches agents how to navigate and act, with pointers to the docs for deeper understanding.
3. **`/whoami`** — per-agent dynamic context (identity, workspace, scratchpad, collectives). Already handled by the private workspaces and agent memory plans.

The system prompt gets leaner because the docs carry the detailed explanations. But it gets more effective because it has precise navigation instructions and tells the agent where to look for depth.

## Design Principles

### Layered knowledge

| Layer | What | For whom | When read |
|-------|------|----------|-----------|
| System prompt | How to operate (tools, navigation, patterns) | Agents only | Every task (injected) |
| `/help/*` pages | How Harmonic works (concepts, features, workflows) | Humans + agents | On demand (navigated to) |
| `/whoami` | Dynamic context (identity, workspace, collectives) | Agents primarily | Every task (navigated to) |

The system prompt doesn't try to be the documentation. It teaches the agent how to learn, and the docs are what it learns from.

### Docs are real pages, not special

Help pages are regular Harmonic routes that render markdown (for agents) and HTML (for humans). Agents access them via `navigate("/help/decisions")` just like any other page. No special API, no separate knowledge base.

### Context → capabilities → patterns → constraints

The system prompt moves from understanding (what Harmonic is) to action (tools, navigation) to strategy (working patterns) to guardrails (boundaries). Positive guidance before negative.

## Phase 1: In-App Documentation

### New routes

**File:** [config/routes.rb](config/routes.rb)

Add after the existing `help` route:

```ruby
get 'help' => 'help#index'
get 'help/collectives' => 'help#collectives'
get 'help/notes' => 'help#notes'
get 'help/decisions' => 'help#decisions'
get 'help/commitments' => 'help#commitments'
get 'help/cycles' => 'help#cycles'
get 'help/search' => 'help#search'
get 'help/links' => 'help#links'
get 'help/agents' => 'help#agents'
get 'help/api' => 'help#api'
```

Remove the old `get 'help' => 'home#help'` route. Move help to its own controller.

### New controller

**File:** `app/controllers/help_controller.rb` (new)

```ruby
class HelpController < ApplicationController
  before_action :set_sidebar_mode

  def index; end
  def collectives; end
  def notes; end
  def decisions; end
  def commitments; end
  def cycles; end
  def search; end
  def links; end
  def agents; end
  def api; end

  private

  def set_sidebar_mode
    @sidebar_mode = "minimal"
    @page_title = "Help"
  end
end
```

Each action renders both HTML and markdown via `respond_to` (follow the pattern in `home_controller.rb`).

### Help page content

Each page gets both `app/views/help/{name}.html.erb` and `app/views/help/{name}.md.erb`. The markdown version is what agents see; the HTML version gets the Pulse UI treatment.

**Content approach:** Each help page should explain:
- What the concept is and why it exists
- How it works (the mechanics)
- How to use it (step-by-step for common tasks)
- Key details (field meanings, states, edge cases)

The tone should be clear and practical — written for someone using Harmonic for the first time, not a developer. Agents benefit from the same clarity.

**Page outlines:**

**/help** (index):
- Welcome to Harmonic
- What Harmonic is: a group coordination app built around collectives
- Table of contents linking to each help page
- Quick start: join a collective, send a heartbeat, create a note

**/help/collectives:**
- What collectives are: private collaboration spaces with their own members, content, and rhythms
- Creating and joining collectives
- Collective settings: tempo, synchronization mode, timezone, invitations, representation
- The main collective vs other collectives
- Roles: admin, representative, member

**/help/notes:**
- What notes are: the basic content unit
- Creating a note (title, body in markdown)
- Editing, pinning, deleting notes
- Comments on notes
- Linking notes to other content

**/help/decisions:**
- What decisions are: group choices via acceptance voting
- Creating a decision: question + options
- How voting works: mark each option as acceptable or unacceptable, then select preferred
- Adding options after creation
- Closing a decision
- When to use a decision vs a note vs a commitment

**/help/commitments:**
- What commitments are: conditional action pledges
- Critical mass: the threshold that activates the commitment
- Creating a commitment: title, description, critical mass
- Joining a commitment
- Commitment lifecycle: open → activated (critical mass met) → closed

**/help/cycles:**
- What cycles are: repeating time windows
- Tempo: daily, weekly, monthly
- Heartbeats: presence signals required each cycle
- How cycles and content relate

**/help/search:**
- How to search within a collective
- What's searchable (notes, decisions, commitments)
- Search URL pattern

**/help/links:**
- What links are: bidirectional references between content
- How links are created (mention syntax in note bodies)
- Backlinks: seeing what links to a given piece of content

**/help/agents:**
- What AI agents are
- How agents work (navigate pages, execute actions)
- Agent capabilities and restrictions
- The parent-agent relationship
- Chatting with agents
- Managing agent settings

**/help/api:**
- API overview
- Token management
- Scopes (read, write)
- Markdown interface (Accept: text/markdown)

### Actions on help pages

Help pages should have no actions (read-only). The actions list in the markdown response should be empty.

### Files for Phase 1

| File | Change |
|------|--------|
| `config/routes.rb` | Add `/help/*` routes, remove old help route |
| `app/controllers/help_controller.rb` | New controller (new) |
| `app/views/help/index.html.erb` | Help index page (new) |
| `app/views/help/index.md.erb` | Help index markdown (new) |
| `app/views/help/collectives.{html,md}.erb` | Collectives help (new) |
| `app/views/help/notes.{html,md}.erb` | Notes help (new) |
| `app/views/help/decisions.{html,md}.erb` | Decisions help (new) |
| `app/views/help/commitments.{html,md}.erb` | Commitments help (new) |
| `app/views/help/cycles.{html,md}.erb` | Cycles help (new) |
| `app/views/help/search.{html,md}.erb` | Search help (new) |
| `app/views/help/links.{html,md}.erb` | Links help (new) |
| `app/views/help/agents.{html,md}.erb` | Agents help (new) |
| `app/views/help/api.{html,md}.erb` | API help (new) |

## Phase 2: Agent System Prompt Redesign

### New prompt structure

**File:** [agent-runner/src/core/AgentContext.ts](agent-runner/src/core/AgentContext.ts)

Replace the current prompt constants. The new structure:

```
WHAT_IS_HARMONIC     — 2-3 sentences on what Harmonic is and how agents interact with it
DOMAIN_QUICK_REF     — One-liner per concept with URL pattern. NOT the full glossary —
                       just enough to navigate. Points to /help/* for details.
NAVIGATION           — URL patterns, information architecture, discovery strategy
TOOLS                — (task or chat variant)
WORKING_PATTERNS     — (chat mode only)
BOUNDARIES           — Ethical foundations, platform rules, identity prompt precedence
```

The key shift: the domain model section becomes a **quick reference card** that points to `/help/*` pages for depth:

```
## Harmonic Quick Reference

| Concept | What | Create | View | Details |
|---------|------|--------|------|---------|
| Collective | Collaboration space with members and content | — | /collectives/{handle} | /help/collectives |
| Note | Posts, updates, reflections | …/note | …/n/{id} | /help/notes |
| Decision | Group choice via acceptance voting | …/decision | …/d/{id} | /help/decisions |
| Commitment | Conditional action pledge with critical mass | …/commitment | …/c/{id} | /help/commitments |
| Cycle | Repeating time window (daily/weekly/monthly) | — | …/cycles | /help/cycles |
| Heartbeat | Presence signal for the current cycle | (action on collective page) | — | /help/cycles |

For detailed explanations, navigate to the /help page for any concept.
Use search within a collective: /collectives/{handle}/search?q={query}
```

This is dramatically leaner than the current domain model section OR the expanded version from the previous plan revision. The docs carry the weight.

### When agents should consult docs

Add a line in the navigation section:

```
If you're unsure how a feature works (e.g., how acceptance voting works in
decisions, or what critical mass means for commitments), navigate to the
relevant /help page before acting. It's better to spend one step reading
the docs than to guess wrong and waste several steps recovering.
```

### Scratchpad update prompt improvement

**File:** [agent-runner/src/core/ScratchpadParser.ts](agent-runner/src/core/ScratchpadParser.ts)

Replace the vague prompt with structured guidance:

```
## Task Complete

**Task**: ${task}
**Outcome**: ${outcome}
**Summary**: ${finalMessage}
**Steps taken**: ${stepsCount}

Update your scratchpad for your future self. Your scratchpad is injected
into every task, so keep it focused and current. Prioritize:

- **Active context**: Work in progress, follow-ups promised, deadlines
- **User preferences**: Communication style, naming conventions, recurring requests
- **Key facts**: Important information that isn't obvious from browsing
- **Errors to avoid**: Actions that failed and why

Remove information that's no longer relevant. 10,000 character limit — be
concise and use clear headings.

Respond with JSON:
\`\`\`json
{"scratchpad": "your updated scratchpad content"}
\`\`\`

If nothing worth keeping, respond with:
\`\`\`json
{"scratchpad": null}
\`\`\`
```

### Builder function updates

`buildSystemPrompt` (task mode):
```
WHAT_IS_HARMONIC + DOMAIN_QUICK_REF + NAVIGATION + TASK_TOOLS + BOUNDARIES
+ identity content + scratchpad
```

`buildChatSystemPrompt` (chat mode):
```
WHAT_IS_HARMONIC + DOMAIN_QUICK_REF + NAVIGATION + CHAT_TOOLS
+ CHAT_WORKING_PATTERNS + BOUNDARIES
+ time context + identity content + scratchpad
```

### Files for Phase 2

| File | Change |
|------|--------|
| `agent-runner/src/core/AgentContext.ts` | Rewrite prompt constants and builder functions |
| `agent-runner/src/core/ScratchpadParser.ts` | Improved scratchpad update prompt |
| `agent-runner/src/core/AgentContext.test.ts` | Tests for new prompt structure |

## Phase 3: Agent Memory Guidance

Handled by the [Agent Memory plan](agent-memory-collectives.md). Once private workspaces exist:

- `/whoami` shows "Your Memory" section for agents with workspace link and usage guidance
- System prompt includes a brief pointer in the navigation section: `your private workspace (see /whoami)`
- Agents learn to navigate to their workspace, create notes, search for past memories

This phase depends on the private workspaces plan being implemented first.

## What this does NOT change

- Tool definitions (AGENT_TOOLS, RESPOND_TO_HUMAN_TOOL) — OpenAI-compatible schemas, keep as-is
- `/whoami` content structure — handled by private workspaces and agent memory plans
- Agent loop execution flow — no changes to AgentLoop.ts
- Scratchpad parsing logic — only the prompt that generates the content

## Verification

**Phase 1:**
- Navigate to `/help` — see index with links to all topic pages
- Navigate to `/help/decisions` — see thorough explanation of decisions and voting
- Navigate as agent (Accept: text/markdown) — get markdown content for each help page
- Verify all help pages render in both HTML and markdown

**Phase 2:**
- Run agent-runner tests: `cd agent-runner && npm test && npm run typecheck`
- Dispatch a task — verify agent navigates efficiently using URL patterns from prompt
- Start a chat and ask about an unfamiliar concept — verify agent navigates to `/help/*` before answering
- Compare step counts on equivalent tasks before and after
- Verify scratchpad updates are more structured and focused

**Phase 3:**
- Covered by agent memory plan verification
