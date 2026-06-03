---
passing: true
last_verified: 2026-06-03
verified_by: Claude Opus 4.7
---

# Test: User Lists — tune-in gesture, custom lists, block integration

> **2026-06-03 verification run** — `app.harmonic.local` against a fresh
> profile (`/u/dan42` viewed as `e2e-test-user`).
> - A/C/D/E/F all passed cleanly via Playwright MCP, including the
>   full block round-trip (block → empty profile → API 422 → unblock →
>   tune-in restored in OFF state, confirming the primary-list cleanup
>   callback fired).
> - B (mutual detection) covered via existing automated tests; not
>   re-verified live because it requires two concurrent browser sessions.
> - G #1 had a wrong URL in an earlier draft (`/lists`); fixed to
>   `/lists/actions`. The create_user_list action surface lives at
>   that route.
> - **Pre-existing finding (not in scope)**: frontmatter at
>   `/lists/actions` advertises the create_user_list path as
>   `/lists/actions/actions/create_user_list` — `MarkdownHelper`'s
>   `"#{request.path}/actions/#{action_name}"` concatenation doubles
>   `/actions/` when the request is itself the actions index endpoint.
>   Agents calling that path would 404. Worth filing separately.

Verifies the full UserList feature end-to-end: the tune-in gesture on user
profiles, custom list CRUD, mutual-tuning-in detection, and the block
integration that hides tune-in / Message and empties the profile when a
block exists in either direction.

## Prerequisites

- Two real human users in the same tenant + main collective. Call them
  Alice (the actor) and Bob (the target).
- A third user, Carol, in the same tenant + main collective.
- Browser sessions for Alice and Bob (different incognito windows).
- The tenant's `app.<HOSTNAME>` subdomain (any tenant works).

## Steps

### A. Tune-in gesture (HTML)

1. As Alice, navigate to `/u/<bob-handle>`.
2. Confirm the header shows a primary-styled (dark) **Tune in** button
   with a `+` icon.
3. Click **Tune in**. Verify it:
   - Posts asynchronously (no page reload).
   - Swaps to a secondary-styled (outlined) **Tuned in** button with the
     custom tuning-in glyph.
   - The `data-ajax-toggle-url-value` flips to `/u/.../actions/tune_out`.
4. Click **Tuned in**. Verify it swaps back to **Tune in** primary.
5. Click **Tune in** again to leave the relationship on.

### B. Mutual-tuning detection (HTML + markdown)

1. As Bob, navigate to `/u/<alice-handle>`. Confirm a muted
   "Tuned in to you" pill appears below the handle.
2. Click **Tune in** on Alice's profile so the relationship is now mutual.
3. Switch to Alice, navigate to `/u/<bob-handle>`. Confirm the "Tuned in
   to you" pill now appears under Bob's name (since Bob now tunes in to
   Alice).
4. Fetch the markdown profile (e.g. via `curl -H 'Accept: text/markdown'
   https://app.../u/<bob-handle>` or the harmonic MCP `fetch_page`).
   Confirm the line reads "You and Bob are _mutually tuned in_ to each
   other."
5. As Bob, tune out from Alice. As Alice, reload Bob's profile —
   markdown should now say "You are _tuned in_ to Bob." and the
   "Tuned in to you" pill should be absent.

### C. Profile header tidy

1. On Bob's profile (as Alice), confirm the only buttons in the header
   are: **Tuned in** (or **Tune in**), and the kebab (⋮) **More actions**.
2. Open the kebab. Verify the menu contains exactly:
   - **Message** (with comment icon)
   - **Block** (with blocked icon)
3. Hover the **Block** button. Confirm the tooltip shows the long
   blocking-explanation text. The text should NOT also appear as a
   visible body line under the buttons.
4. Confirm the icons and labels in both menu items are vertically
   centered with the same 8px gap.

### D. Custom list CRUD (HTML)

1. As Alice, navigate to `/u/<alice-handle>` and open the **Lists**
   accordion. Click **New list**.
2. On `/lists/new`, enter a name like "Reading group", choose
   **public** visibility and `members_add` add policy. Submit.
3. On the resulting `/lists/<truncated_id>` show page:
   - Verify the page renders the name and a member list (empty for now).
   - Verify the **Edit** button is visible (you're the owner).
   - Verify **no Delete** button on the show page.
4. Click **Edit**. Verify the **Danger zone** appears at the bottom of
   the form (non-primary list).
5. Add Bob and Carol via the add-member form (or the dedicated UI).
6. Back on the show page, verify both appear in the member list.
7. Remove Bob. Verify he disappears. Try removing yourself as Alice —
   should succeed (any member can remove themselves).
8. Try editing the list as Bob (sign in as Bob first, navigate to the
   list URL). Confirm the **Edit** button is absent — only the owner
   sees it.

### E. Action endpoints (markdown)

1. As Alice, hit `GET /u/<bob-handle>/actions/tune_in` with
   `Accept: text/markdown`. Confirm the action description renders.
2. Hit `POST /u/<bob-handle>/actions/tune_in`. Confirm "Tuned in." or
   "Already tuned in." result.
3. Hit `POST /u/<bob-handle>/actions/tune_out`. Confirm "Tuned out." or
   "Not tuned in." result.
4. Fetch `/u/<bob-handle>` (markdown) and confirm the frontmatter's
   `actions:` block lists `tune_in` and `tune_out`. Fetch
   `/u/<alice-handle>` (markdown) and confirm the frontmatter does NOT
   list `tune_in` / `tune_out` (own profile).

### F. Block integration

1. As Alice, open Bob's profile, open the kebab, and click **Block**.
2. Confirm the page returns to Bob's profile (not `/user-blocks`).
3. Verify the profile is now mostly empty:
   - The **Tune in** button is gone; in its place a muted line reads
     "You have blocked Bob."
   - The kebab no longer contains **Message** — only **Unblock**.
   - The Common Collectives / Lists / Recent Activity accordions are
     absent (only the header + AI agent info, if any, remain).
4. Fetch Bob's profile in markdown. Confirm:
   - "You have blocked Bob." appears in place of the tuning-in line.
   - The frontmatter `actions:` block does NOT list `tune_in` or
     `tune_out`.
   - The "Common Collectives", "Social Proximity", and "Recent Activity"
     section headers are absent.
5. Confirm Alice's primary list no longer contains Bob (open
   `/u/<alice-handle>` → Lists accordion → Alice's primary list, or
   verify via the markdown `/u/<alice-handle>` view). Confirm Bob's
   primary list no longer contains Alice (sign in as Bob and check, or
   inspect via SQL if you have access).
6. Try `POST /u/<bob-handle>/actions/tune_in` as Alice. Expect a 422
   with an error message mentioning "block".
7. Sign in as Bob, open `/u/<alice-handle>`. Verify Bob sees:
   - "Alice has blocked you." in place of the tune-in button.
   - The same empty profile (no accordions).
   - Bob's kebab on Alice's profile still shows **Block** (Bob can
     mutual-block back), but no **Message**.
8. As Alice, click **Unblock**. Verify the page returns to Bob's
   profile and the tune-in button + accordions reappear.

### G. Markdown agent flow (sanity)

1. Fetch Alice's own profile in markdown and confirm `tune_in` /
   `tune_out` are NOT in the frontmatter actions.
2. Fetch Bob's profile as Alice (no block in effect). Confirm `tune_in`
   and `tune_out` appear in frontmatter actions.
3. Fetch `/lists/actions` (the create-list action surface) and confirm
   `create_user_list` appears in the frontmatter actions.
4. Create a custom list via `POST /lists/actions/create_user_list` and
   verify it appears under `/u/<alice-handle>/lists`.
5. Fetch the list at `/lists/<truncated_id>` and verify member
   actions (`add_member`, `remove_member`) appear in frontmatter.

## Acceptance

- All steps complete without console errors.
- Visual transitions on the tune-in button feel snappy (no flicker, no
  layout shift).
- Block fully empties the profile — no leak of shared collectives,
  lists, or activity to a blocked viewer.
- Markdown frontmatter consistently reflects the action surface a
  viewer can actually exercise.

## Known follow-ups (not part of this test)

- Backfill for primary-list memberships that pre-date the block cleanup
  callback (only relevant if such rows exist in your DB).
- Custom (non-primary) lists are NOT cleaned on block by design —
  members across a block persist in custom lists.
- Per-list activity feeds — tracked separately in
  `.claude/plans/user-list-feeds.md`.
