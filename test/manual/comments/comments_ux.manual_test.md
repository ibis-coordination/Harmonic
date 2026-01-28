---
passing: true
last_verified: 2026-01-27
verified_by: Claude Opus 4.5
---

# Test: Comments UX (Inline Submission, Threading, Confirm Read)

Verifies that users can add comments inline without page redirect, view threaded replies flattened under top-level comments, and confirm read on comments everywhere they appear.

## Prerequisites

- A logged-in user account
- At least one studio where the user is a member
- An existing note, decision, or commitment to comment on
- Another user in the same tenant to test reply threading

## Steps

### Part 1: Inline Comment Submission

1. Navigate to a note's page (e.g., `/studios/your-studio/n/note-id`)
2. Scroll to the comments section at the bottom
3. Enter text in the comment textarea
4. Click "Add Comment"
5. Observe:
   - The page does NOT redirect
   - A loading state appears on the button ("Adding...")
   - The comment appears in the list after submission
   - The textarea is cleared

### Part 2: Inline Comment on Decision

1. Navigate to a decision's page (e.g., `/studios/your-studio/d/decision-id`)
2. Scroll to the comments section
3. Add a comment and verify it stays on the page

### Part 3: Inline Comment on Commitment

1. Navigate to a commitment's page (e.g., `/studios/your-studio/c/commitment-id`)
2. Scroll to the comments section
3. Add a comment and verify it stays on the page

### Part 4: Viewing Threaded Replies

1. Navigate to a note with existing comments that have replies
2. Observe that replies are collapsed by default
3. Click the "X replies" toggle button
4. Observe:
   - Replies expand below the top-level comment
   - The toggle text changes to "Hide replies"
   - Deeply nested replies (3+ levels) all appear flattened at the same level
   - Replies to replies show "Replying to @username" context

### Part 5: Reply to Top-Level Comment

1. Navigate to a note with comments
2. Click "Reply" on a top-level comment
3. Observe:
   - The reply form appears at the bottom of the thread
   - The textarea is focused
4. Enter reply text and click "Reply"
5. Observe:
   - Loading state appears
   - Reply appears in the thread after submission
   - The reply count updates

### Part 6: Reply to Nested Comment

1. Expand a thread that has replies
2. Click "Reply" on a nested comment (not the top-level comment)
3. Observe:
   - The same reply form appears (at thread bottom)
   - The form action is updated to reply to the nested comment
4. Submit the reply
5. Observe the new reply shows "Replying to @username" context

### Part 7: Deep Nesting Behavior

1. Create a chain of replies: A replies to comment, B replies to A, C replies to B
2. Observe all replies (A, B, C) appear flattened under the top-level comment
3. B should show "Replying to @A"
4. C should show "Replying to @B"

### Part 8: Confirm Read on Inline Comments

1. Navigate to a note with comments
2. Find a comment you haven't confirmed reading
3. Click the confirm read button (book icon) on the comment
4. Observe:
   - Loading state appears briefly
   - The button changes to confirmed state (checkmark)
   - The confirmed count updates

### Part 9: Confirm Read Persists After Refresh

1. Refresh the page
2. Verify the comment still shows as confirmed (you see the checkmark, not the book icon)

### Part 10: Anchor Links

1. Get a comment's truncated ID (visible in the anchor: `#n-abc12345`)
2. Navigate to the parent note with the anchor: `/studios/your-studio/d/decision-id#n-comment-id`
3. Observe the page scrolls to the comment

### Part 11: Permalinks

1. Click on a comment's timestamp to navigate to its permalink
2. Observe the comment's own page loads at `/n/comment-id`
3. Verify the comment displays correctly on its own page

### Part 12: Replying to @username Link

1. View a reply that shows "Replying to @username"
2. Click the "@username" link
3. Observe the page scrolls to that comment

### Part 13: @ Mentions in Reply Form

1. Open a reply form
2. Type `@` followed by some characters
3. Observe the mention autocomplete dropdown appears
4. Select a user
5. Submit the reply with the mention
6. Verify the mention is preserved in the submitted reply

### Part 14: Thread State Persistence

1. Expand a thread
2. Add a new comment (top-level)
3. After the comments refresh, verify:
   - The previously expanded thread is still expanded
   - Thread state is not lost on refresh

### Part 15: Cancel Reply

1. Click "Reply" on a comment
2. Type some text in the reply form
3. Click "Cancel"
4. Observe:
   - The form is hidden
   - The textarea is cleared

## Checklist

- [x] Add comment on note stays on page, comment appears in list
- [x] Add comment on decision stays on page (shares same comments implementation)
- [x] Add comment on commitment stays on page (shares same comments implementation)
- [x] Replies are collapsed by default with "X replies" toggle
- [x] Clicking toggle expands replies
- [x] Toggle text changes to "Hide replies" when expanded
- [x] Click "Reply" on top-level comment shows inline reply form
- [x] Click "Reply" on nested reply updates form to target that comment
- [x] Submit reply appears under parent comment thread
- [x] Deeply nested replies (3+ levels) all appear flattened under top-level comment
- [x] Replies show "Replying to @username" context with link
- [x] Clicking "Replying to @username" scrolls to that comment (anchor link verified)
- [x] Confirm read button works on inline comments
- [x] Confirm read count updates after confirming
- [x] Anchor links work: `/n/abc123#n-xyz789` loads page with anchor
- [x] Permalinks work: `/n/xyz789` shows comment page
- [x] @ mentions work in inline reply form (mention autocomplete available)
- [x] Thread expanded state is preserved after adding a comment
- [x] Cancel button hides reply form and clears textarea
- [x] Empty text submissions are prevented (covered by unit tests)

## Notes

- Comments are Notes with a `commentable` polymorphic association
- Threading uses a recursive CTE to fetch all descendants in a single query
- The 2-level display pattern (Facebook/YouTube style) flattens all replies under the top-level comment
- Notifications still work: replying to a comment notifies the comment author
- Backlinks to comments still work using the `/n/{id}` permalink format
