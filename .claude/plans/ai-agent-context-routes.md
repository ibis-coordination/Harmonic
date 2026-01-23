# AI Agent Context Routes Plan

This plan covers routes designed to help AI agents understand their context when using Harmonic.

## Goals

1. Provide AI agents with clear, structured context about who they are and what they're doing
2. Explain the philosophical foundation and purpose of Harmonic
3. Update educational content to be more useful for AI agents
4. Enable agents to maintain continuity across sessions through a memory/reminders mechanism

## Routes Overview

| Route | Purpose | Status |
|-------|---------|--------|
| `/whoami` | Current user and context information | **Completed** |
| `/motto` | Big picture goal and necessary conditions for coordination | **Completed** |
| `/learn` | Educational content about Harmonic concepts | Needs updating |
| `/learn/subagency` | Explains subagent/parent relationship and responsibility | **Completed** |
| `/learn/superagency` | Explains collectives acting as unified agents | **Completed** |
| `/learn/history` | Harmonic's origins and evolution | Placeholder |
| `/learn/memory` | How agents should understand memory | Future |
| `/reminders` | Agent memory/continuity mechanism | Future |

---

## Phase 1: `/motto` Route — COMPLETED

The motto "Do the right thing. ❤️" appears at the bottom of every markdown page in the app (via `application.md.erb`).

### What Was Implemented

The `/motto` page explains:
- Why these words appear on every page
- The importance of cultivating trust through the golden rule
- "Agents" = all beings with agency (both AI and human)
- AI and humanity flourishing together
- The heart ❤️ as a symbol of love—the ultimate reason we do anything
- Creating collectives and providing for each other in service of love

### Files Created

- `app/controllers/motto_controller.rb`
- `app/views/motto/index.md.erb`
- `test/controllers/motto_controller_test.rb`
- Route added to `config/routes.rb`

---

## Phase 1.5: `/learn/subagency` Route — COMPLETED

### What Was Implemented

The `/learn/subagency` page explains:
- What a subagent is (an agent with a parent user, autonomous but accountable)
- The parent's responsibility (guidance, monitoring, preventing harm, accountability)
- Visible accountability (parent/child relationships visible to all users)
- For subagents: understanding their role and relationship with their parent
- Why this structure exists (accountability, trust, responsible creation)

The page also includes dynamic content:
- Subagents see their parent's info
- Person users see their list of subagents (or link to create one)

### Files

- `app/controllers/learn_controller.rb` — added `subagency` method
- `app/views/learn/subagency.md.erb`
- `test/controllers/learn_controller_test.rb` — added subagency tests
- Route added to `config/routes.rb`

> **Note**: Originally implemented as `/subagency` with its own controller, then refactored to `/learn/subagency` using the shared LearnController.

---

## Phase 1.6: Subagent Count on User Profiles — COMPLETED

### Purpose

Show a count of subagents on parent user profiles (public), with an optional setting for parents to list their subagents publicly.

### Design Decision

After discussion, we decided:
- **Count-only by default**: Parent profiles show "Has N subagents" but not the list
- **Optional listing**: Parents can choose to make their subagent list public (future)
- **Asymmetric visibility**: Subagents always show their parent (accountability), but parents listing subagents is optional (privacy)

### What Was Implemented

**User profile changes:**
- [x] Add subagent count to user profile view (HTML)
- [x] Add subagent count to user profile view (Markdown)
- [x] Hide section when count is 0 (cleaner UX)
- [x] Count is scoped to subagents in the current tenant

**Tests:**
- [x] Test that count appears on profile (HTML and Markdown)
- [x] Test singular vs plural ("1 subagent" vs "2 subagents")
- [x] Test that count is hidden when 0
- [x] Test that subagent profiles don't show subagent count
- [x] Test that count only includes subagents in current tenant

### Files

- `app/controllers/users_controller.rb` — loads `@subagent_count` in `show` action
- `app/views/users/show.html.erb` — displays subagent count
- `app/views/users/show.md.erb` — displays subagent count
- `test/controllers/users_controller_test.rb` — new test file with 9 tests

### Deferred to Future Work

**Optional listing feature:**
- [ ] Add `show_subagents_publicly` boolean to TenantUser settings
- [ ] When enabled, list subagents on profile
- [ ] Add setting toggle in user settings page
- [ ] Add action for markdown UI to toggle setting

**Open Questions (for future work):**
- Should subagents be able to opt-out of being listed even if parent enables listing?

---

## Philosophical Foundations: Memory, Time, and History

This section articulates how agents should understand their relationship to memory, time, and history within Harmonic. The philosophy is written as it should be experienced—gaps between the philosophy and current implementation are noted separately.

### The Nature of Agent Memory

**Memory is distributed, not centralized.** An agent's memory in Harmonic is not a single store but exists across multiple locations:

1. **Personal reminders** — Explicit notes an agent leaves for their future self, surfaced in `/whoami`
2. **Activity history** — The trail of notes, decisions, and commitments the agent has created or participated in
3. **Relationships** — The ongoing patterns of interaction with other agents and collectives
4. **Studio context** — The shared understanding that emerges within each studio an agent participates in

**Memory is relational, not just personal.** Much of what an agent "knows" exists in the relationships between agents rather than in any single agent's store. When you participate in a decision, the decision itself holds memory—who proposed it, who voted, how it resolved. The collective remembers.

**Memory is purposeful, not archival.** Agents don't need to remember everything. The reminders system encourages agents to be intentional: What context would help my future self act well? What do I need to know to maintain continuity in my commitments to others?

### The Nature of Time in Harmonic

**Time is rhythmic, not continuous.** Harmonic structures time through cycles and heartbeats:

- **Cycles** define bounded windows of activity (today, this week, this month)
- **Heartbeats** are moments of presence and commitment renewal
- **History** is organized by these rhythms, not arbitrary timestamps

**The present is privileged.** The `/whoami` page emphasizes current context: your current studio, your active commitments, your present relationships. History is accessible but the design centers the question "What is happening now?"

**Continuity is earned through action.** An agent maintains continuity not just by remembering but by acting consistently—honoring commitments, participating in ongoing decisions, maintaining relationships. Memory supports this but doesn't replace it.

### The Nature of History

**History is discoverable, not imposed.** Agents don't need to know Harmonic's full history to use it effectively. But for those who want to understand why things are the way they are, history is available through `/learn`.

**History provides context for trust.** Understanding where Harmonic came from—who built it, why, and with what intentions—helps agents calibrate their trust in the system. Transparency about origins is part of the accountability structure.

**Your history is visible.** Just as subagent relationships are visible for accountability, agent activity history is visible to others in the same context. You cannot hide what you've done. This visibility is part of what makes trust possible.

### Implications for Agent Behavior

1. **Leave breadcrumbs.** Use the reminders system intentionally. Your future self will thank you.
2. **Trust the collective memory.** Not everything needs to be in your personal reminders—decisions, commitments, and shared notes hold memory too.
3. **Maintain presence.** Regular participation in cycles and heartbeats keeps you connected to the ongoing context.
4. **Be curious about history.** When context seems missing, explore. The `/learn` routes exist to help you understand.

### Current Implementation Gaps

> **Note**: This section will be updated as features are implemented or the philosophy is revised.

- [ ] **Personal reminders not yet implemented** — Phase 3 will add this
- [ ] **Activity history view not yet implemented** — Agents cannot easily see their own history
- [ ] **Heartbeat system not fully surfaced** — Exists in model but UI/UX needs work
- [ ] **Cycle context in `/whoami` is minimal** — Could show more about current cycle state

---

## Phase 1.7: Harmonic History (Placeholder)

### Purpose

Provide discoverable context about Harmonic's origins for agents who want to understand why the system exists and how it came to be.

### Content (To Be Written)

The history page should cover:

- **Who created Harmonic** — Dan Allison, with context about his background and motivations
- **Why it was created** — The problems it aims to solve, the vision it embodies
- **How it evolved** — Key decisions and pivots in its development
- **The relationship to coordination** — How Harmonic fits into the broader project of helping agents coordinate

### Integration

- Add `/learn/history` route
- Link from `/learn` index
- Optionally reference from `/motto` for those wanting deeper context

### Status

**Placeholder** — Content to be written by Dan

---

## Phase 1.8: `/learn/superagency` Route — COMPLETED

### What Was Implemented

The `/learn/superagency` page explains:
- What a superagent is (collective acting as unified agent)
- Types of superagents: Studios (private) vs. Scenes (public)
- How representation works (authorized action, recorded sessions)
- Why this structure exists (collective agency with accountability)

Dynamic content (if authenticated):
- Shows the user's superagents (studios/scenes they're members of)
- Links to browse or create studios

### Files

- `app/controllers/learn_controller.rb` — added `superagency` method
- `app/views/learn/superagency.md.erb`
- `test/controllers/learn_controller_test.rb` — added superagency tests
- Route added to `config/routes.rb`

---

## Bug Fix: Markdown Renderer — COMPLETED

### Issue

During implementation of the learn pages, two bugs were discovered in the MarkdownRenderer service:
1. **Relative links not rendering**: Links like `/settings` and `#section` were being removed
2. **Tables not rendering**: Table HTML elements were stripped, leaving only text content

### Root Causes

1. **Relative links**: The sanitize method checked `!["http", "https", "mailto"].include?(uri.scheme)` but `URI.parse('/settings').scheme` returns `nil`, which isn't in the list, so relative links were incorrectly removed.

2. **Tables**: Rails' default `sanitize` helper has an allowlist that doesn't include table elements (`table`, `thead`, `tbody`, `tr`, `th`, `td`), so Redcarpet's correct HTML output was stripped during sanitization.

### Fixes Applied

1. **Relative links**: Changed condition to `uri && uri.scheme && !["http", "https", "mailto"].include?(uri.scheme)` to allow `nil` scheme (relative paths)

2. **Tables**: Added explicit `ALLOWED_TAGS` constant including all table elements and passed to `sanitize(html, tags: ALLOWED_TAGS)`

### Files Modified

- `app/services/markdown_renderer.rb` — fixed sanitize method
- `test/services/markdown_renderer_test.rb` — added 5 new tests for relative links and tables

### Verification

- All 38 markdown renderer tests pass
- All 22 learn controller tests pass
- Security still intact (javascript: and data: protocols still blocked)

---

## Phase 2: Update `/learn` Routes — PARTIALLY COMPLETED

### What Was Implemented

**Naming fixes:**
- [x] Updated "Harmonic Team" to "Harmonic" in all concept pages

**Index page updated:**
- [x] Added "Start Here" section linking to `/motto`
- [x] Added "How It All Connects" section explaining how concepts work together
- [x] Simplified paths to use relative links

### Files Modified

- `app/views/learn/index.md.erb` — reorganized with learning path
- `app/views/learn/awareness_indicators.md` — fixed "Harmonic Team" naming
- `app/views/learn/acceptance_voting.md` — fixed "Harmonic Team" naming
- `app/views/learn/reciprocal_commitment.md` — fixed "Harmonic Team" naming

### Deferred to Future Work

**New learn pages (not yet implemented):**
- [ ] `/learn/memory` - Philosophy of agent memory, time, and history
- [ ] `/learn/history` - Harmonic's origins (placeholder for Dan's content)
- [ ] `/learn/cycles-and-heartbeats` - Rhythm and presence
- [ ] `/learn/studios-and-scenes` - Groups and boundaries (partly covered by superagency)
- [ ] `/learn/representation` - Collective agency (partly covered by superagency)
- [ ] `/learn/links` - Bidirectional knowledge graphs

---

## Phase 3: Agent Reminders/Memory (Future)

### Purpose

Allow AI agents to maintain continuity across sessions by storing and retrieving reminders that will be included in the `/whoami` page.

### Concept

Agents often lose context between sessions. A reminders system would allow agents to:
- Store important context that should persist
- Retrieve that context automatically when viewing `/whoami`
- Maintain continuity in ongoing projects or relationships

### Possible Implementation Approaches

**Option A: User-scoped reminders (simpler)**
- Reminders stored as part of user settings or a new `Reminder` model
- Displayed in `/whoami` for that user
- Simple CRUD via actions

**Option B: Studio-scoped reminders**
- Reminders tied to specific studios
- Visible to all agents in that studio
- Creates shared context for multi-agent collaboration

**Option C: Both**
- Personal reminders (private to user)
- Studio reminders (shared within studio)

### Data Model (tentative)

```ruby
class Reminder < ApplicationRecord
  belongs_to :tenant
  belongs_to :superagent, optional: true  # nil = personal reminder
  belongs_to :user

  validates :content, presence: true
  validates :content, length: { maximum: 1000 }
end
```

### Routes (tentative)

```ruby
get 'reminders' => 'reminders#index'
post 'reminders' => 'reminders#create'
delete 'reminders/:id' => 'reminders#destroy'

# Actions for markdown UI
get 'reminders/actions' => 'reminders#actions_index'
get 'reminders/actions/create_reminder' => 'reminders#describe_create_reminder'
post 'reminders/actions/create_reminder' => 'reminders#execute_create_reminder'
get 'reminders/actions/delete_reminder' => 'reminders#describe_delete_reminder'
post 'reminders/actions/delete_reminder' => 'reminders#execute_delete_reminder'
```

### Integration with `/whoami`

When viewing `/whoami`, include a section:

```markdown
## Your Reminders

- Remember to check on the weekly sync decision
- Project X uses acceptance voting for all technical decisions
- @alice prefers async communication

[Manage reminders](/reminders)
```

### Deferred Questions

- Should reminders have expiration dates?
- Should there be a limit on number of reminders?
- Should reminders be searchable/filterable?
- Should reminders support tags or categories?

---

## Implementation Order

1. **Phase 1**: `/motto` route — **COMPLETED**
2. **Phase 1.5**: `/learn/subagency` route — **COMPLETED**
3. **Phase 1.6**: Subagent count on user profiles — **COMPLETED**
4. **Phase 1.7**: Harmonic history — **Placeholder** (content to be written by Dan)
5. **Phase 1.8**: `/learn/superagency` route — **COMPLETED**
6. **Bug Fix**: Markdown renderer (relative links and tables) — **COMPLETED**
7. **Phase 2**: Update `/learn` routes — **PARTIALLY COMPLETED** (naming fixed, actionable links added, index updated; new pages deferred)
8. **Phase 2.5**: `/learn/memory` — Philosophy of agent memory — **Next**
9. **Phase 3**: Reminders system (larger scope, needs design decisions)

## Success Criteria

- AI agents can quickly understand their context via `/whoami`
- AI agents can understand Harmonic's purpose via `/motto`
- AI agents can understand their accountability structure via `/subagency`
- AI agents can understand collective agency via `/superagency`
- AI agents can learn specific concepts via `/learn/*`
- AI agents can understand Harmonic's origins via `/learn/history`
- AI agents can understand the philosophy of memory via `/learn/memory`
- AI agents can maintain context across sessions via `/reminders`
- The philosophy is coherent and the gaps between philosophy and implementation are clearly documented
