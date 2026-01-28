# Comments UX Improvements Plan

## Overview

This plan addresses three UX issues with the comments system:

1. **Inline Comment Submission**: Comment form submission redirects to the comment's show page instead of staying on the current page
2. **Nested Comment Threads**: Nested comments (replies to comments) are only visible on the comment's show page, not inline
3. **Confirm Read Everywhere**: The "Confirm Read" action for comments is only available in the studio feed and on the comment's show page

---

## Key Decisions (Summary)

These decisions were made during planning and should be followed during implementation:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Threading approach** | 2-level flattening (Facebook/YouTube) | Avoids deep nesting UX problems; keeps conversations readable |
| **Descendant fetching** | Recursive CTE (Option B) | Shows ALL descendants inline; no navigation needed for deep threads |
| **Anchor ID format** | `id="n-{truncated_id}"` | Uses `n-` prefix because comments are Notes (`/n/` paths), consistent with `/d/` and `/c/` |
| **Permalinks** | Keep existing `/n/{id}` pages | Backlinks require stable permalinks; inline display is additive |
| **Gem usage** | None needed | PostgreSQL recursive CTE handles tree traversal; existing `commentable` provides structure |
| **Notifications** | No changes | Data model unchanged; `comment.commentable.created_by` still gets notified |
| **Multi-tenancy** | Explicit filtering in CTE | `find_by_sql` bypasses `default_scope`; must filter by `tenant_id` and `superagent_id` |

### Two URLs Per Comment

| URL | Purpose |
|-----|---------|
| `/d/abc123#n-xyz789` | Comment in context (scrolls to it on parent page) |
| `/n/xyz789` | Permalink (for backlinks, sharing) |

---

## Research: How Other Apps Handle Threaded Comments

### Common Patterns

| App | Approach | Pros | Cons |
|-----|----------|------|------|
| **Twitter/X** | Linear with side threads; click reply to see its thread | Clean main view | Requires navigation for deep threads |
| **Slack** | Reply creates thread in side panel; main channel stays linear | Gold standard for organization | More complex UI |
| **Reddit** | Deep nesting with collapse/expand | Full context visible | Gets messy, "where am I?" problem |
| **Facebook/YouTube** | **2-level max**; replies to replies flatten to level 2 | Simple, mobile-friendly | Less precise threading |
| **GitHub Issues** | Completely flat, chronological | Simple | No threading at all |

### Expert Opinion

Jeff Atwood (Stack Overflow co-founder) [argues against deep threading](https://blog.codinghorror.com/web-discussions-flat-by-design/):

> "Rigid hierarchy is generally not how the human mind works... Discussion trees force me to spend too much time mentally managing that two-dimensional tree more than the underlying discussion."

> "Always favor simple, flat discussions instead."

### Recommendation: 2-Level Flattening (Facebook/YouTube Pattern)

**Why this works for Harmonic:**
- Avoids deep nesting UX problems
- No need for collapse/expand complexity
- Works well on mobile
- No external gem required (existing `commentable` relationship is sufficient)
- Keeps conversations readable

**How it works:**
1. **Level 0**: Top-level comments on the resource (Decision, Commitment, Note)
2. **Level 1**: All replies appear directly under the comment they're replying to, at the same indentation
3. **No Level 2+**: Replying to a reply adds to the same flat list, with "Replying to @username" context

---

## Permalinks and Anchors

Every comment maintains its permalink for backlinks while also being viewable inline.

### Two URLs, Both Work

| URL | Purpose |
|-----|---------|
| `/d/abc123#n-xyz789` | Decision page, scrolled to comment `xyz789` in thread |
| `/n/xyz789` | Comment's own page (for backlinks, sharing) |

**Why `n-` prefix**: Comments are Notes, and notes use `/n/` paths. This is consistent with decisions (`/d/`) and commitments (`/c/`).

### Implementation

1. **Inline display with anchors**: Each comment element has `id="n-{truncated_id}"`
2. **Permalinks still work**: `/n/{id}` renders the comment's show page unchanged
3. **Backlinks work**: `Link` model points to `/n/{id}`, backlinks display correctly
4. **"View in thread" link**: Comment show page can link to parent + anchor

---

## Current Architecture

### Comments Are Notes

Comments are `Note` records with a polymorphic `commentable` association:
- `commentable_type`: Class name of parent (Note, Decision, Commitment)
- `commentable_id`: UUID of parent
- Notes include `Commentable` concern, so comments can have replies

### Key Files

| File | Purpose |
|------|---------|
| [app/models/note.rb](app/models/note.rb) | Note model with `is_comment?`, `commentable` |
| [app/models/concerns/commentable.rb](app/models/concerns/commentable.rb) | Concern providing `comments` relation |
| [app/controllers/application_controller.rb:544-551](app/controllers/application_controller.rb#L544-L551) | `create_comment` action (currently redirects) |
| [app/views/shared/_pulse_comments.html.erb](app/views/shared/_pulse_comments.html.erb) | Comment display partial |
| [app/javascript/controllers/pulse_action_controller.ts](app/javascript/controllers/pulse_action_controller.ts) | AJAX action button controller |

---

## Phase 1: Inline Comment Submission

**Goal**: After submitting a comment, the new comment appears in the list without leaving the page.

### Approach: Stimulus Controller with HTML Replacement

Use a Stimulus controller (similar to `pulse_action_controller.ts`) to:
1. Intercept form submission
2. POST via fetch
3. Replace the comments section with updated HTML from server

### Changes Required

#### 1.1 Create Comments Controller

**File**: `app/javascript/controllers/comments_controller.ts`

```typescript
import { Controller } from "@hotwired/stimulus"

export default class CommentsController extends Controller {
  static targets = ["form", "list", "textarea"]
  static values = {
    refreshUrl: String,  // URL to fetch updated comments HTML
  }

  async submit(event: Event): Promise<void> {
    event.preventDefault()
    const form = this.formTarget as HTMLFormElement
    const formData = new FormData(form)

    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: { "X-CSRF-Token": this.csrfToken },
        body: formData,
      })

      if (response.ok) {
        // Refresh the comments list
        const html = await fetch(this.refreshUrlValue).then(r => r.text())
        this.listTarget.outerHTML = html
        this.textareaTarget.value = ""
      }
    } catch (error) {
      console.error("Error submitting comment:", error)
    }
  }

  get csrfToken(): string {
    return document.querySelector("meta[name='csrf-token']")?.content ?? ""
  }
}
```

#### 1.2 New Controller Action: Render Comments Section

**File**: `app/controllers/application_controller.rb`

```ruby
def comments_partial
  render partial: 'shared/pulse_comments',
         locals: { commentable: current_resource },
         layout: false
end
```

#### 1.3 New Routes

**File**: `config/routes.rb`

Add to Notes, Decisions, Commitments resource blocks:
```ruby
get '/comments.html' => 'notes#comments_partial'
get '/comments.html' => 'decisions#comments_partial'
get '/comments.html' => 'commitments#comments_partial'
```

#### 1.4 Modify `create_comment` for AJAX

**File**: `app/controllers/application_controller.rb`

```ruby
def create_comment
  if current_resource.is_commentable?
    comment = api_helper.create_note(commentable: current_resource)

    respond_to do |format|
      format.html { redirect_to comment.path }
      format.json { render json: { success: true, comment_id: comment.truncated_id } }
    end
  else
    render status: 405, json: { message: 'comments cannot be added to this datatype' }
  end
end
```

#### 1.5 Update Comments Partial

**File**: `app/views/shared/_pulse_comments.html.erb`

```erb
<div class="pulse-comments-section"
     data-controller="comments"
     data-comments-refresh-url-value="<%= commentable.path %>/comments.html">
  <div class="pulse-section-label">
    <%= octicon 'comment', height: 12 %>
    Comments (<%= commentable.comment_count %>)
  </div>

  <div data-comments-target="list">
    <%# Comment list content %>
  </div>

  <% if @current_user %>
    <%= form_with url: "#{commentable.path}/comments", method: :post,
                  data: { comments_target: "form", action: "submit->comments#submit" } do |form| %>
      <%= form.text_area :text, data: { comments_target: "textarea" }, ... %>
      <%= form.submit "Add Comment" %>
    <% end %>
  <% end %>
</div>
```

---

## Phase 2: Inline Reply Threads (Flattened Descendants)

**Goal**: Show all replies to comments inline, flattened under each top-level comment.

### Approach: Recursive CTE for All Descendants

- Top-level comments display normally
- **All descendants** (replies, replies to replies, etc.) appear in a flat list under the top-level comment
- Displayed chronologically within each thread
- "Replying to @username" context shows who each reply is responding to
- Reply form appears inline when "Reply" is clicked

### Example Display

```
Alice's Note (the resource)
│
├── Bob's comment (9:00am)                    ← top-level
│   ┌─────────────────────────────────────┐
│   │ Dave (9:15am)                       │   ← reply to Bob
│   │ Frank (9:30am) · Replying to @Dave  │   ← reply to Dave (flattened)
│   │ Grace (9:45am)                      │   ← reply to Bob
│   │ [Reply form]                        │
│   └─────────────────────────────────────┘
│
└── Carol's comment (9:10am)                  ← top-level
    ┌─────────────────────────────────────┐
    │ Eve (9:20am)                        │   ← reply to Carol
    │ [Reply form]                        │
    └─────────────────────────────────────┘
```

### Changes Required

#### 2.1 Add Recursive Descendants Method to Note Model

**File**: `app/models/note.rb`

```ruby
# Returns all descendants (replies, replies to replies, etc.) chronologically
# Uses PostgreSQL recursive CTE for efficient single-query fetching
# IMPORTANT: find_by_sql bypasses default_scope, so we must filter by tenant/superagent
def all_descendants
  return Note.none unless persisted?

  Note.find_by_sql([<<-SQL.squish, id, tenant_id, superagent_id, tenant_id, superagent_id])
    WITH RECURSIVE descendants AS (
      -- Base case: direct replies to this note
      SELECT notes.*, 1 as depth
      FROM notes
      WHERE notes.commentable_id = ?
        AND notes.commentable_type = 'Note'
        AND notes.tenant_id = ?
        AND notes.superagent_id = ?

      UNION ALL

      -- Recursive case: replies to descendants
      SELECT n.*, d.depth + 1
      FROM notes n
      INNER JOIN descendants d ON n.commentable_id = d.id
        AND n.commentable_type = 'Note'
      WHERE n.tenant_id = ?
        AND n.superagent_id = ?
    )
    SELECT * FROM descendants
    ORDER BY created_at ASC
  SQL
end

# Preload associations for a collection of notes (avoids N+1)
def self.preload_for_display(notes)
  ActiveRecord::Associations::Preloader.new(
    records: notes,
    associations: [:created_by, :commentable]
  ).call
  notes
end
```

**Note**: The `find_by_sql` bypasses ActiveRecord's `default_scope`, so we explicitly filter by `tenant_id` and `superagent_id` to maintain multi-tenancy isolation.

#### 2.2 Add Helper Method to Commentable Concern

**File**: `app/models/concerns/commentable.rb`

```ruby
# Returns top-level comments with their descendants preloaded
def comments_with_threads
  top_level = chronological_comments.includes(:created_by)

  # Build a hash of comment_id => descendants for efficient lookup
  threads = {}
  top_level.each do |comment|
    descendants = comment.all_descendants
    Note.preload_for_display(descendants)
    threads[comment.id] = descendants
  end

  { top_level: top_level, threads: threads }
end
```

#### 2.3 Create Comment Partial

**File**: `app/views/shared/_pulse_comment.html.erb`

```erb
<%# Single comment display %>
<%# locals: comment, show_reply_context (boolean), root_comment_id (for reply form targeting) %>
<div class="pulse-comment" id="n-<%= comment.truncated_id %>">
  <div class="pulse-comment-header">
    <div class="pulse-author-avatar">
      <% if comment.created_by.image.attached? %>
        <img src="<%= comment.created_by.image_path %>" alt="" class="pulse-avatar-img">
      <% end %>
      <span class="pulse-avatar-initials"><%= comment.created_by.display_name.first.upcase %></span>
    </div>
    <a href="<%= comment.created_by.path %>" class="pulse-comment-author">
      <%= comment.created_by.display_name %>
    </a>
    <a href="<%= comment.path %>" class="pulse-comment-timestamp"><%= timeago(comment.created_at) %></a>
    <%= render 'shared/pulse_comment_confirm', note: comment %>
  </div>

  <% if show_reply_context && comment.commentable_type == 'Note' %>
    <div class="pulse-comment-reply-context">
      <%= octicon 'reply', height: 12 %>
      Replying to
      <a href="#n-<%= comment.commentable.truncated_id %>">@<%= comment.commentable.created_by.handle %></a>
    </div>
  <% end %>

  <div class="pulse-comment-body">
    <%= markdown_inline(comment.text) %>
  </div>

  <div class="pulse-comment-actions">
    <button class="pulse-comment-reply-btn"
            data-action="click->comment-thread#showReplyForm"
            data-comment-id="<%= comment.truncated_id %>"
            data-root-comment-id="<%= root_comment_id %>">
      Reply
    </button>
  </div>
</div>
```

#### 2.4 Update Comments List Structure

**File**: `app/views/shared/_pulse_comments.html.erb`

```erb
<%
  comment_data = commentable.comments_with_threads
  top_level_comments = comment_data[:top_level]
  threads = comment_data[:threads]
%>

<div class="pulse-comments-list" data-comments-target="list" data-controller="comment-thread">
  <% top_level_comments.each do |comment| %>
    <%# Top-level comment %>
    <%= render 'shared/pulse_comment',
               comment: comment,
               show_reply_context: false,
               root_comment_id: comment.truncated_id %>

    <%# All descendants flattened %>
    <% descendants = threads[comment.id] || [] %>
    <% if descendants.any? %>
      <div class="pulse-comment-replies">
        <% descendants.each do |reply| %>
          <%# Show "Replying to" context if replying to someone other than the top-level comment author %>
          <% show_context = reply.commentable_id != comment.id %>
          <%= render 'shared/pulse_comment',
                     comment: reply,
                     show_reply_context: show_context,
                     root_comment_id: comment.truncated_id %>
        <% end %>
      </div>
    <% end %>

    <%# Reply form for this thread (hidden by default) %>
    <div class="pulse-reply-form-container" id="reply-form-<%= comment.truncated_id %>" hidden>
      <%= form_with url: "#{comment.path}/comments", method: :post,
                    data: { action: "submit->comment-thread#submitReply" },
                    class: "pulse-reply-form" do |form| %>
        <input type="hidden" name="reply_to_id" id="reply-to-<%= comment.truncated_id %>" value="<%= comment.truncated_id %>">
        <div class="pulse-form-group mention-autocomplete-container"
             data-controller="mention-autocomplete"
             data-mention-autocomplete-studio-path-value="<%= @current_superagent.path %>">
          <%= form.text_area :text,
                             placeholder: "Write a reply...",
                             rows: 2,
                             class: "pulse-form-textarea",
                             data: { mention_autocomplete_target: "input" } %>
          <div data-mention-autocomplete-target="dropdown" class="mention-dropdown"></div>
        </div>
        <div class="pulse-reply-form-actions">
          <button type="button"
                  class="pulse-btn-secondary"
                  data-action="click->comment-thread#hideReplyForm">
            Cancel
          </button>
          <%= form.submit "Reply", class: "pulse-feed-action-btn" %>
        </div>
      <% end %>
    </div>
  <% end %>
</div>
```

#### 2.5 Create Comment Thread Controller

**File**: `app/javascript/controllers/comment_thread_controller.ts`

```typescript
import { Controller } from "@hotwired/stimulus"

/**
 * Handles inline reply forms within comment threads.
 * - Shows/hides reply forms
 * - Updates the reply target when replying to nested comments
 * - Submits replies via AJAX and refreshes the thread
 */
export default class CommentThreadController extends Controller {
  static targets = ["list"]

  declare readonly listTarget: HTMLElement

  get csrfToken(): string {
    return document.querySelector("meta[name='csrf-token']")?.content ?? ""
  }

  showReplyForm(event: Event): void {
    const button = event.currentTarget as HTMLElement
    const commentId = button.dataset.commentId
    const rootCommentId = button.dataset.rootCommentId

    // Hide any other open reply forms
    this.element.querySelectorAll(".pulse-reply-form-container").forEach(el => {
      ;(el as HTMLElement).hidden = true
    })

    // Show the reply form for this thread
    const formContainer = document.getElementById(`reply-form-${rootCommentId}`)
    if (formContainer) {
      formContainer.hidden = false

      // Update the form action to reply to the correct comment
      const form = formContainer.querySelector("form") as HTMLFormElement
      if (form && commentId) {
        // Update form action to point to the comment being replied to
        const basePath = form.action.replace(/\/n\/[^/]+\/comments/, "")
        form.action = `${basePath}/n/${commentId}/comments`

        // Update hidden field
        const hiddenInput = formContainer.querySelector(`#reply-to-${rootCommentId}`) as HTMLInputElement
        if (hiddenInput) {
          hiddenInput.value = commentId
        }
      }

      formContainer.querySelector("textarea")?.focus()
    }
  }

  hideReplyForm(event: Event): void {
    const formContainer = (event.currentTarget as HTMLElement).closest(".pulse-reply-form-container") as HTMLElement
    if (formContainer) {
      formContainer.hidden = true
      // Clear the textarea
      const textarea = formContainer.querySelector("textarea") as HTMLTextAreaElement
      if (textarea) textarea.value = ""
    }
  }

  async submitReply(event: Event): Promise<void> {
    event.preventDefault()
    const form = event.currentTarget as HTMLFormElement
    const formData = new FormData(form)
    const formContainer = form.closest(".pulse-reply-form-container") as HTMLElement

    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: { "X-CSRF-Token": this.csrfToken },
        body: formData,
      })

      if (response.ok) {
        // Hide the form and clear it
        if (formContainer) {
          formContainer.hidden = true
          const textarea = form.querySelector("textarea") as HTMLTextAreaElement
          if (textarea) textarea.value = ""
        }

        // Trigger a refresh of the comments section
        // The parent comments controller will handle this
        this.dispatch("replyAdded", { detail: { formAction: form.action } })
      }
    } catch (error) {
      console.error("Error submitting reply:", error)
    }
  }
}
```

#### 2.6 Styles for Reply Threading

**File**: `app/assets/stylesheets/pulse/_comments.scss`

```scss
.pulse-comment-replies {
  margin-left: 2.5rem;
  padding-left: 1rem;
  border-left: 2px solid var(--border-subtle);
  margin-top: 0.5rem;
  margin-bottom: 0.5rem;
}

.pulse-comment-reply-context {
  display: flex;
  align-items: center;
  gap: 0.25rem;
  font-size: 0.85em;
  color: var(--text-muted);
  margin-bottom: 0.25rem;

  a {
    color: var(--text-muted);
    text-decoration: none;

    &:hover {
      text-decoration: underline;
    }
  }
}

.pulse-reply-form-container {
  margin-left: 2.5rem;
  padding-left: 1rem;
  border-left: 2px solid var(--border-subtle);
  margin-top: 0.5rem;
}

.pulse-reply-form {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.pulse-reply-form-actions {
  display: flex;
  gap: 0.5rem;
  justify-content: flex-end;
}
```

---

## Phase 3: Confirm Read Everywhere

**Goal**: Allow confirming read on any comment, wherever it appears.

### Approach: Reusable Confirm Read Component

Reuse existing `pulse_action_controller.ts` pattern.

### Changes Required

#### 3.1 Create Confirm Read Partial

**File**: `app/views/shared/_pulse_comment_confirm.html.erb`

```erb
<%# Usage: render 'shared/pulse_comment_confirm', note: comment %>
<% if @current_user %>
  <% user_has_read = note.user_has_read?(@current_user) %>
  <span class="pulse-comment-confirm"
        data-controller="pulse-action"
        data-pulse-action-url-value="<%= note.path %>/actions/confirm_read"
        data-pulse-action-loading-text-value="..."
        data-pulse-action-confirmed-text-value="">
    <% if user_has_read %>
      <span class="pulse-comment-confirmed" title="You confirmed reading this">
        <%= octicon 'check', height: 12 %>
      </span>
    <% else %>
      <button type="button"
              class="pulse-comment-confirm-btn"
              data-pulse-action-target="button"
              data-action="click->pulse-action#performAction"
              title="Confirm you have read this comment">
        <%= octicon 'book', height: 12 %>
      </button>
    <% end %>
  </span>
<% end %>
```

#### 3.2 Styles

```scss
.pulse-comment-confirm {
  margin-left: auto;  // Push to right side of header
}

.pulse-comment-confirm-btn {
  opacity: 0.5;
  transition: opacity 0.15s;

  &:hover {
    opacity: 1;
  }
}

.pulse-comment-confirmed {
  color: var(--success-color);
}
```

---

## Implementation Order

1. **Phase 2a (Descendants Query)** - Foundation for thread display
   - Add `all_descendants` method to Note model (recursive CTE)
   - Add `comments_with_threads` helper to Commentable concern
   - Add `preload_for_display` class method to Note
   - Write model tests for descendants query

2. **Phase 1 (Inline Submission)** - AJAX comment creation
   - Create `comments_controller.ts`
   - Add `comments_partial` action and routes
   - Modify `create_comment` for JSON response
   - Update `_pulse_comments.html.erb` with Stimulus controller

3. **Phase 2b (Thread Display)** - Builds on Phase 2a
   - Create `_pulse_comment.html.erb` partial with anchor IDs
   - Update `_pulse_comments.html.erb` to use `comments_with_threads`
   - Create `comment_thread_controller.ts` for inline reply forms
   - Style reply indentation and context links

4. **Phase 3 (Confirm Read)** - Independent, can run in parallel
   - Create `_pulse_comment_confirm.html.erb`
   - Add to comment header in `_pulse_comment.html.erb`
   - Reuses existing `pulse_action_controller.ts`

---

## Testing Plan

### Unit Tests
- `test/controllers/notes_controller_test.rb`: Test `comments_partial` action
- `test/controllers/application_controller_test.rb`: Test JSON response from `create_comment`

### Integration Tests
- `test/integration/comments_test.rb`: Test full comment creation flow

### Frontend Tests
- `app/javascript/controllers/comments_controller.test.ts`: Test form submission
- `app/javascript/controllers/comment_thread_controller.test.ts`: Test reply form toggle

### Model Tests
- `test/models/note_test.rb`:
  - Test `all_descendants` returns empty for note with no replies
  - Test `all_descendants` returns direct replies
  - Test `all_descendants` returns deeply nested replies (3+ levels)
  - Test `all_descendants` returns replies in chronological order
  - Test `all_descendants` doesn't return unrelated notes

### Manual Tests
Create `test/manual/comments_ux.manual_test.md`:
- [ ] Add comment on note, stays on page, comment appears in list
- [ ] Add comment on decision, stays on page
- [ ] Add comment on commitment, stays on page
- [ ] Click Reply on top-level comment, form appears inline
- [ ] Click Reply on nested reply, form appears and targets correct comment
- [ ] Submit reply, appears under parent comment thread
- [ ] Deeply nested replies (3+ levels) all appear flattened under top-level comment
- [ ] Replies show "Replying to @username" context with link to that comment
- [ ] Clicking "Replying to @username" scrolls to that comment
- [ ] Confirm read button works on inline comments at all nesting levels
- [ ] Anchor links work: `/d/abc123#n-xyz789` scrolls to comment
- [ ] Permalinks work: `/n/xyz789` shows comment page
- [ ] Backlinks still work for comments
- [ ] @ mentions work in inline reply form
- [ ] Notifications still work: replying to a comment notifies the comment author

---

## Why No Gem Is Needed

The existing architecture already supports nested comments:
- `Note` has `belongs_to :commentable, polymorphic: true`
- `Note` includes `Commentable` concern, giving it `has_many :comments`
- Query: `comment.commentable` gets parent, `comment.comments` gets direct replies

For fetching **all descendants** (not just direct children), we use a PostgreSQL recursive CTE:

```ruby
# In Note model
def all_descendants
  Note.find_by_sql([<<-SQL.squish, id, tenant_id, superagent_id, tenant_id, superagent_id])
    WITH RECURSIVE descendants AS (
      SELECT notes.*, 1 as depth FROM notes
      WHERE commentable_id = ? AND commentable_type = 'Note'
        AND tenant_id = ? AND superagent_id = ?
      UNION ALL
      SELECT n.*, d.depth + 1 FROM notes n
      INNER JOIN descendants d ON n.commentable_id = d.id AND n.commentable_type = 'Note'
      WHERE n.tenant_id = ? AND n.superagent_id = ?
    )
    SELECT * FROM descendants ORDER BY created_at ASC
  SQL
end
```

This fetches all descendants in a **single query**, regardless of nesting depth. No gem needed because:
1. PostgreSQL handles the recursion efficiently
2. We display results flat (no tree structure needed in Ruby)
3. The `commentable` relationship already provides parent context for "Replying to @username"
4. Multi-tenancy is enforced explicitly since `find_by_sql` bypasses `default_scope`

---

## Future Considerations

- **Real-time updates**: WebSocket/Turbo Streams for live comment updates
- **Comment editing**: Inline edit functionality
- **Comment deletion**: Soft delete with "deleted" placeholder
- **View in thread**: Link from comment show page to parent + anchor
- **Notification improvements**: "Someone replied to your comment" notifications
