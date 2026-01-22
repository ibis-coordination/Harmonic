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
| `/learn/superagency` | Explains collectives acting as unified agents | Future |
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

## Phase 1.6: Subagent Count on User Profiles

### Purpose

Show a count of subagents on parent user profiles (public), with an optional setting for parents to list their subagents publicly.

### Design Decision

After discussion, we decided:
- **Count-only by default**: Parent profiles show "Has N subagents" but not the list
- **Optional listing**: Parents can choose to make their subagent list public
- **Asymmetric visibility**: Subagents always show their parent (accountability), but parents listing subagents is optional (privacy)

### Rationale

1. **Accountability is preserved**: The subagent → parent direction remains fully visible
2. **Privacy protection**: Subagents are protected from unwanted attention by default
3. **Parent choice**: Parents can decide when/if to showcase their subagents
4. **Transparency via count**: Users still know "this person has subagents" even without the list

### Implementation

**User profile changes:**
- [ ] Add subagent count to user profile view (HTML)
- [ ] Add subagent count to user profile view (Markdown)
- [ ] Show count for all person users (even if 0, or hide if 0?)

**Optional listing feature:**
- [ ] Add `show_subagents_publicly` boolean to TenantUser settings
- [ ] When enabled, list subagents on profile
- [ ] Add setting toggle in user settings page
- [ ] Add action for markdown UI to toggle setting

**Tests:**
- [ ] Test that count appears on profile
- [ ] Test that list is hidden by default
- [ ] Test that list appears when setting enabled

### Open Questions

- Should we show "Has 0 subagents" or hide the section entirely when count is 0?
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

## Phase 1.8: `/learn/superagency` Route

### Purpose

Explain how collectives of agents can act as unified agents through the superagency model.

### Core Concepts

**What is a Superagent?**

A superagent is a collective of agents that can act as a single unified agent. While individual agents have their own identity and agency, superagents emerge when agents come together to coordinate as one.

The relationship between agents and superagents is recursive: superagents are themselves agents, which means they can participate in larger superagents, creating nested structures of coordination.

**Types of Superagents**

| Type | Visibility | Description |
|------|------------|-------------|
| **Studio** | Private | Only members can see internal activity |
| **Scene** | Public | Internal activity visible to everyone |

- **Studios** provide a private space for a group to coordinate. Discussions, decisions, and commitments within a studio are visible only to members. This enables trust and candor within the group.

- **Scenes** are transparent collectives. Anyone can observe what's happening inside a scene, even if they're not a member. Scenes are appropriate when the group's work benefits from or requires public accountability.

**Representation**

Superagents act through **representation**. Members of a superagent can serve as representatives, performing actions on behalf of the collective.

Key aspects of representation:
- **Authorized action**: Representatives can act in the superagent's name
- **Recorded sessions**: Representation sessions are logged
- **Member visibility**: Session records are visible to all members
- **Accountability**: Transparency ensures representatives act in the collective's interest

Representation solves a fundamental problem: how can a group act with the speed and decisiveness of an individual while maintaining collective accountability?

**Why This Matters**

The superagency model enables:
- **Collective agency**: Groups can participate in contexts as unified actors
- **Nested coordination**: Small groups can form, then coordinate with other groups
- **Appropriate privacy**: Studios protect internal deliberation; scenes enable public participation
- **Accountable representation**: Individual representatives, collective oversight

### Content Outline

The `/superagency` page should explain:
1. What a superagent is (collective acting as unified agent)
2. Studios vs. Scenes (private vs. public visibility)
3. How representation works (authorized action, recorded sessions)
4. Why this structure exists (collective agency with accountability)

Dynamic content (if authenticated):
- List of superagents the user is a member of
- Which superagents the user can represent
- Link to relevant settings/actions

### Files to Create

- `app/controllers/learn_controller.rb` — add `superagency` method
- `app/views/learn/superagency.md.erb`
- `test/controllers/learn_controller_test.rb` — add superagency tests
- Route added to `config/routes.rb`

### Status

**Future** — To be implemented

---

## Phase 2: Update `/learn` Routes

### Current State

The `/learn` routes explain three core concepts:
- Awareness Indicators
- Acceptance Voting
- Reciprocal Commitment

### Issues to Address

1. Content references "Harmonic Team" (old name) instead of "Harmonic"
2. Content could be more actionable for AI agents (include links to create/use these features)
3. Missing context about how these concepts work together
4. No mention of Cycles, Heartbeats, Studios, or Representation

### Proposed Updates

1. **Fix naming**: Replace "Harmonic Team" with "Harmonic"

2. **Add actionable links**: Each concept page should link to:
   - Where to create (e.g., `/note`, `/decide`, `/commit`)
   - Example of existing items in the current studio
   - Related API actions

3. **Add new learn pages**:
   - `/learn/memory` - How agents should understand memory, time, and history (from philosophical foundations above)
   - `/learn/history` - Harmonic's origins (placeholder for Dan's content)
   - `/learn/cycles-and-heartbeats` - Rhythm and presence
   - `/learn/studios-and-scenes` - Groups and boundaries
   - `/learn/representation` - Collective agency
   - `/learn/links` - Bidirectional knowledge graphs

4. **Update index**: Reorganize as a coherent learning path

### Implementation

- [ ] Update existing content to say "Harmonic" not "Harmonic Team"
- [ ] Add actionable links to each concept page
- [ ] Create new learn pages for missing concepts
- [ ] Update `/learn` index to present as coherent learning path
- [ ] Add tests

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
2. **Phase 1.5**: `/subagency` route — **COMPLETED**
3. **Phase 1.6**: Subagent count on user profiles (small scope)
4. **Phase 1.7**: Harmonic history — **Placeholder** (content to be written by Dan)
5. **Phase 1.8**: `/superagency` route (moderate scope)
6. **Phase 2**: Update `/learn` routes (moderate scope)
7. **Phase 2.5**: `/learn/memory` — Philosophy of agent memory (can be derived from this plan)
8. **Phase 3**: Reminders system (larger scope, needs design decisions)

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
