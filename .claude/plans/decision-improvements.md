# Decision Improvements

## Context

Before implementing decision subtypes (lottery, log), the base decision experience needs several UX improvements. The current show page requires navigating to a separate settings page to close a decision, votes fire immediately on each checkbox click (no batch submit), results are always visible (enabling strategic voting), individual votes aren't visible, and there's no way to annotate the outcome after closing. These changes will also lay groundwork for the decision subtypes.

## Changes

### 1. Close decision action + show page button

**Action:** Add a `close_decision` action (POST) accessible from both HTML and markdown UIs. This sets the deadline to `Time.current` (same as existing "close_now" settings flow). Owner-only.

**HTML show page:** Add a "Close Decision" button in the header actions bar (next to Settings/Copy link), visible only to the decision owner when the decision is open. Uses `turbo_confirm` for confirmation.

**Markdown:** The action should appear in the actions index (`/actions/close_decision`) so agents and markdown users can close decisions without navigating to settings.

**Files:**
- `app/views/decisions/show.html.erb` — add close button in `header.with_actions` block
- `app/controllers/decisions_controller.rb` — add `close_decision` action (POST, owner-only)
- `config/routes.rb` — add `post '/actions/close_decision'` route
- `app/services/api_helper.rb` — add `close_decision` helper (or reuse `update_decision_settings` with close_now)

### 2. Batch vote submission

Replace per-checkbox-click voting with a batch submit flow. Users check/star options locally (no API calls), then click a "Submit Votes" button that sends all votes in one request. After submission, the UI shows their current votes and allows re-submission (revising votes).

**Files:**
- `app/javascript/controllers/decision_controller.ts` — remove API calls from checkbox handlers; track local vote state; add `submitVotes` method that POSTs all votes at once
- `app/views/decisions/_options_section.html.erb` — add "Submit Votes" button below options list
- `app/views/decisions/_options_list_items.html.erb` — remove `data-action="click->decision#toggleVoteValues"` from checkboxes (keep local toggle behavior)
- `app/controllers/decisions_controller.rb` — verify the existing `vote` action handles full replacement semantics (all options in one call)
- `app/services/api_helper.rb` — verify/update `create_votes` to handle batch submission

### 3. Hide results until after voting

Results section is hidden for users who haven't voted yet. After submitting votes, results become visible. For unauthenticated users, results are hidden with a message. For closed decisions, results are always visible.

Applies to **both HTML and markdown views**.

**Files:**
- `app/controllers/decisions_controller.rb` — set `@current_user_has_voted` flag in `show` action (check if participant has any votes)
- `app/views/decisions/show.html.erb` — conditionally render results section based on `@current_user_has_voted || @decision.closed?`
- `app/views/decisions/show.md.erb` — same conditional: hide results table and voters section until user has voted or decision is closed
- `app/javascript/controllers/decision_controller.ts` — after successful vote submission, unhide the results section (or reload page)

### 4. Voters detail page

Add a dedicated voters page at `/d/:decision_id/voters` that shows the full breakdown of who voted for what. The show page links to this page instead of displaying per-option voter details inline, keeping the show page concise.

**Voters page content:** A table/list showing each option with the users who accepted and/or preferred it, making it clear that votes are not anonymous.

**Files:**
- `config/routes.rb` — add `get '/voters'` route (currently only `/voters.html` partial exists)
- `app/controllers/decisions_controller.rb` — add `voters` action that loads votes with participants grouped by option
- `app/views/decisions/voters.html.erb` — full page showing per-option voter breakdown
- `app/views/decisions/voters.md.erb` — markdown version of the same
- `app/views/decisions/show.html.erb` — replace inline voters section with link to voters page
- `app/views/decisions/show.md.erb` — add link to voters page
- `app/models/decision.rb` — add method to get votes grouped by option with user info

### 5. Final statement field

Add a `final_statement` text column to decisions. This field is only editable after the decision is closed. It provides the owner's interpretation of the results — especially important for the log subtype.

Displayed in **both HTML and markdown views** when present.

**Files:**
- Migration — add `final_statement` (text, nullable) to `decisions` table
- `app/models/decision.rb` — no special validation needed (editability enforced at controller/view level)
- `app/views/decisions/show.html.erb` — display final statement below results when present; show edit form for owner when decision is closed
- `app/views/decisions/show.md.erb` — display final statement below results when present
- `app/controllers/decisions_controller.rb` — add `update_final_statement` action (POST, owner-only, decision must be closed)
- `config/routes.rb` — add route for update_final_statement
- `app/services/api_helper.rb` — add helper for updating final statement

### 6. Update help documentation

Update the decisions help page and voting instructions to reflect all changes. Key updates:

- **Votes are NOT anonymous** — make this explicit (currently says "individual votes are not visible to other members," which will be wrong after the voters page). Update to explain that votes are visible via the voters page.
- **Batch voting** — update the "Voting" section to describe the submit button flow
- **Results visibility** — explain that results are hidden until you vote (to prevent strategic voting)
- **Close button** — update "Closing a Decision" to mention the close button on the show page (not just settings)
- **Final statement** — add section explaining the final statement and when it can be edited
- **Voters page** — document the voters page and what it shows

**Files:**
- `app/views/help/decisions.md.erb` — update all sections as described above
- `app/views/decisions/_acceptance_voting_tooltip.html.erb` — update tooltip to mention submit button and non-anonymous voting

## Implementation Order

1. **Final statement field** — migration + model, simple and independent
2. **Close decision action + show page button** — enables testing the final statement flow
3. **Batch vote submission** — refactor the Stimulus controller and voting UI
4. **Hide results until after voting** — depends on batch submit (need to know when user has "submitted")
5. **Voters detail page** — independent but best done after results visibility changes
6. **Update help documentation** — do last since it documents the final state of all changes

## Verification

- Write tests for each change following red-green TDD
- Run `./scripts/run-tests.sh` for backend tests
- Run `docker compose exec js npm test` for frontend tests
- Run `docker compose exec web bundle exec rubocop` for linting
- Run `docker compose exec web bundle exec srb tc` for type checking
- Manual browser testing on `https://app.harmonic.local`:
  - Create a decision, add options, verify close button appears for owner only
  - Vote with batch submit, verify results appear after submission
  - Close decision, add final statement, verify it displays
  - Check as a second user: results hidden before voting, visible after
  - Navigate to voters page, verify per-option voter breakdown is correct
  - Test markdown view: results hidden before voting, final statement visible, close action available
  - Verify help page content is accurate and complete
