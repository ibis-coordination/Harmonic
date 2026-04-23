# Plan: User Blocking — Design & Implementation

## Context

The `UserBlock` model, controller, and routes are already in place (backend skeleton). This plan covers the **design decisions, UX integration, and enforcement effects** needed to make blocking a real, complete feature.

Harmonic is a coordination platform, not a broadcast/engagement platform. This fundamentally shapes how blocking works. On Twitter, blocking controls your audience. On Harmonic, blocking maintains a healthy coordination space — you need to work with people in your collectives without harassment or disruption.

**This is the first feature in the safety sequence:** blocking → content deletion → content reporting. Reporting will build on blocking (e.g., "report and block" combined action).

## Research: How Other Platforms Handle Blocking

### Twitter/X (broadcast model)
- Blocked user can't follow, reply, like, repost, or DM you
- Recently changed: blocked users **can** view public posts (controversial)
- Blocking is asymmetric — only the blocker controls it
- Discovery: three-dot menu on profiles and tweets

### Discord (community/chat model)
- Blocked user's messages are hidden (collapsed with "Show message" option)
- Can't DM you
- Can still see and reply to your messages in shared servers
- You see "[Blocked Message]" placeholders
- Discovery: right-click on username

### Slack (workplace model)
- No traditional blocking (by design — it's a work tool)
- Recently added "Hide Person" (2024) �� collapses their messages, removes from sidebar
- Hidden users can still see your messages and mention you
- Workspace admins can see who's hidden whom

### Key Insight
The more coordination-oriented the platform, the softer the blocking. Discord lets you hide messages but doesn't remove the person from shared spaces. Slack barely blocks at all. Twitter has the hardest block because it's a broadcast platform where you control your audience.

**Harmonic is closest to Discord/Slack** — people share collectives and need to coordinate. A hard Twitter-style block that makes someone invisible would break coordination. But users still need real protection from harassment.

## Design Decisions

### 1. What blocking means on Harmonic

Blocking is a **personal filter**, not an exile. It protects the blocker from unwanted interaction without removing the blocked user from shared coordination spaces.

**Effects on the blocker's experience:**
- Blocked user's content is **collapsed/hidden** in feeds and comment threads (with a "Show" toggle, like Discord)
- Blocked user cannot **@mention** the blocker (filtered from autocomplete; if they type it manually, the mention doesn't generate a notification)
- Blocked user cannot **comment** on the blocker's notes/decisions/commitments
- Notifications from the blocked user are **suppressed** (not delivered)

**What blocking does NOT do:**
- Does not remove the blocked user from shared collectives
- Does not hide the blocker's content from the blocked user (Harmonic content is collective-scoped, not personal)
- Does not prevent the blocked user from participating in the same decisions/commitments (they can still vote and join — you just don't see their participation in your feed)
- Does not notify the blocked user that they've been blocked

**Rationale:** Harmonic collectives are coordination spaces. If blocking could remove someone's ability to participate in a shared decision, it would give individual users veto power over collective processes. The blocked user can still participate — the blocker just doesn't have to see their content or receive their direct interactions.

**Scope:** Blocking is **tenant-wide**. If you block someone in one collective, they're blocked across all collectives in that tenant. If someone is harassing you, they're harassing you regardless of which collective you're in.

### 2. Discovery — where users find the block action

**Primary:** Action button on user profiles (`/u/:handle`)
- "Block @handle" button when not blocked
- "Unblock @handle" button when blocked
- Not shown on your own profile
- Not shown on AI agents (admin can suspend those directly)

**Secondary:** User settings → "Blocked Users" accordion section
- Shows count badge when > 0
- Links to `/user-blocks` (list of blocked users with unblock buttons — already implemented)

### 3. Feedback — what the user sees

**After blocking:**
- Flash: "@handle has been blocked. You won't see their content or receive interactions from them."
- Profile page reloads showing "Unblock" option

**After unblocking:**
- Flash: "@handle has been unblocked."

**No notification** sent to the blocked user in either direction.

### 4. Content hiding (feed/comment collapse)

When a user has blocked someone, that person's content appears collapsed in feeds and comment threads:

**Collapsed state:**
- Single line: "Content from a blocked user" with a "Show" toggle
- Styled muted/subtle so it doesn't draw attention
- Uses a Stimulus controller (`blocked_content_controller.ts`)

**Expanded state (after clicking Show):**
- Content rendered normally but with a subtle visual indicator (muted border or badge)
- "Hide" toggle to collapse again
- Expansion is per-viewing, not persistent — refreshing the page collapses it again

**Implementation approach:**
- Pass blocked user IDs to the frontend via a data attribute on the body element (lightweight, no extra request)
- Stimulus controller checks `data-blocked-user-ids` against content author IDs
- Works on the Pulse feed, note/decision/commitment show pages (comment threads), and any other content listing

### 5. Admin visibility

- App admin user detail page (`/app-admin/users/:id`) shows blocks_given and blocks_received counts as informational metrics
- No admin override of blocks (blocks are personal)
- A user with many blocks_received may warrant admin investigation — but this is observational, not automated

## Implementation

### Phase 1: Backend enforcement

**Comment blocking** — `app/services/api_helper.rb`:
- In `create_note` (line ~145), when creating a comment (commentable present): check if `UserBlock.between?(current_user, commentable.created_by)` 
- If blocked in either direction, return validation error: "You cannot comment on this user's content"
- This is the centralized CRUD logic, so it covers both HTML and API paths

**@mention filtering** — `app/controllers/autocomplete_controller.rb`:
- When building mention suggestions, exclude users who have blocked the current user
- Also exclude users the current user has blocked (you don't want to mention someone you've blocked)

**Notification suppression** — `app/jobs/notification_delivery_job.rb`:
- Before delivering a notification, check if the recipient has blocked the notification's actor
- If blocked, skip delivery (mark as suppressed, don't delete the notification record)

### Phase 2: Frontend content hiding

**Blocked user IDs in page context:**
- In `ApplicationController`, set `@blocked_user_ids` (array of IDs the current user has blocked)
- Render as `data-blocked-user-ids` attribute on the `<body>` tag in the layout

**Stimulus controller** — `app/javascript/controllers/blocked_content_controller.ts`:
- Connects to content items (feed items, comments)
- Checks if the content author ID is in the blocked list
- Toggles collapse/expand state
- Uses existing CSS patterns for muted/collapsed appearance

**View integration:**
- Add `data-controller="blocked-content"` and `data-blocked-content-author-id-value="<%= item.created_by_id %>"` to feed items and comment components

### Phase 3: UI integration

**User profile** (`app/views/users/show.html.erb`):
- Block/Unblock button in the user actions area
- Condition: logged in, not own profile, not AI agent
- Uses `button_to` for POST `/user-blocks` (block) and DELETE `/user-blocks/:id` (unblock)

**User settings** (`app/views/users/settings.html.erb`):
- "Blocked Users" accordion section (for human users viewing own settings)
- Count badge showing number of blocked users
- Link to `/user-blocks`

**Admin user detail** (`app/views/app_admin/show_user.html.erb`):
- Informational: "Blocks given: N / Blocks received: N"

### Phase 4: Tests

**Backend enforcement:**
- Integration test: blocked user cannot comment on blocker's content (via API helper)
- Integration test: blocker cannot comment on blocked user's content (bidirectional)
- Integration test: blocked user doesn't appear in @mention autocomplete for blocker
- Integration test: blocker doesn't appear in @mention autocomplete for blocked user
- Integration test: notification not delivered when recipient has blocked the actor

**Frontend:**
- Stimulus controller test: content collapses when author is in blocked list
- Stimulus controller test: Show/Hide toggle works

**UI integration:**
- Controller test: block button appears on other user's profile
- Controller test: block button hidden on own profile
- Controller test: unblock works from profile and from /user-blocks list

## Open Questions

1. **What about AI agents?** Currently excluded from block UI. A spamming AI agent should be suspended by its parent or admin, not blocked by individual users. Revisit if needed.

2. **Should blocked users' votes be hidden in decision results?** Probably not — decision results should reflect the full collective's input. The blocker sees the aggregate result, not individual votes. But if results show individual voter names, the blocked user's name should be visually de-emphasized.

3. **Edge case: what if the only other participant in a decision has blocked you?** You can still participate. Blocking is about the blocker's experience, not the blocked user's capabilities.

## References

- [Slack "Hide Person" feature](https://slack.com/blog/news/new-hide-person-feature)
- [Discord blocking](https://discord.fandom.com/wiki/Blocking)
- [X blocking changes](https://www.socialmediatoday.com/news/x-formerly-twitter-dilutes-the-power-of-blocking/730113/)
