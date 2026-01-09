# Markdown UI Bugs

This document tracks bugs discovered while testing the markdown/MCP interface.

## Summary

Testing was performed using the MCP server's `navigate` and `execute_action` tools against the markdown API endpoints (`Accept: text/markdown`).

---

## 500 Internal Server Errors

### 1. Cycle Detail Pages
**Affected paths:**
- `/studios/:handle/cycles/today`
- `/studios/:handle/cycles/yesterday`
- `/studios/:handle/cycles/tomorrow`
- `/studios/:handle/cycles/this-week`
- `/studios/:handle/cycles/last-week`
- `/studios/:handle/cycles/next-week`
- (likely all cycle detail pages)

**Expected:** Markdown listing of items in the cycle
**Actual:** 500 Internal Server Error

**Notes:** The cycles index page (`/studios/:handle/cycles`) works correctly and shows counts. Only the detail views fail.

---

### 2. Add Option Action on Decisions
**Affected path:** `/studios/:handle/d/:id/actions/add_option`
**Method:** POST

**Steps to reproduce:**
1. Navigate to a decision page
2. Execute `add_option` with `{"text": "Option text"}`

**Expected:** Option added successfully
**Actual:** 500 Internal Server Error

---

## 406 Not Acceptable Errors (Markdown format not supported)

These pages don't have markdown rendering implemented.

### 1. New Commitment Page
**Path:** `/studios/:handle/commit`

### 2. Representation Pages
**Path:** `/studios/:handle/r/:id`

### 3. User Profile Pages
**Path:** `/u/:handle`

### 4. Studio Join Page
**Path:** `/studios/:handle/join`

---

## 404 Not Found Errors

### 1. Join Commitment Action
**Path:** `/studios/:handle/c/:id/actions/join_commitment`
**Method:** POST

**Notes:** The commitment detail page shows this action as available, but the route doesn't exist.

---

## Empty/Missing Responses

### 1. Studio Team Page
**Path:** `/studios/:handle/team`
**Actual:** Empty response (no content)

---

## Missing Heartbeat Feature

The markdown UI does not implement the heartbeat requirement that exists in the HTML UI.

**Expected behavior:**
1. Studio homepage should display heartbeat information (last heartbeat time, cycle status)
2. If user has NOT sent a heartbeat for the current cycle:
   - Studio homepage should ONLY display the `send_heartbeat` action
   - All other content/actions should be hidden until heartbeat is sent
3. Users must send a heartbeat once per cycle to access studio content

**Current behavior:**
- No heartbeat information displayed
- No `send_heartbeat` action available
- No gating of studio content based on heartbeat status

**Required changes:**
- [ ] Add heartbeat status to studio homepage markdown
- [ ] Add `send_heartbeat` action
- [ ] Implement heartbeat gate: if no heartbeat this cycle, only show `send_heartbeat`
- [ ] Add `POST /studios/:handle/actions/send_heartbeat` route

---

## Inconsistent Action Formatting

Some pages use different formats for documenting available actions:

**Good format (machine-readable):**
```markdown
## Actions

* `create_decision(question, description, deadline, options_open)` to create a new decision.
```

**Missing from some pages:**
- Consistent `## Available Actions` section with parameter descriptions
- Some pages mix prose descriptions with action syntax

---

## Missing add_comment Action

All commentable resources (notes, decisions, commitments, representation sessions) should have an `add_comment` action available via the markdown UI.

**Current behavior:**
- POST `/comments` routes exist but only work for HTML UI (redirect after create)
- No `add_comment` action routes for markdown UI

**Required changes:**
- [x] Add `GET /studios/:handle/n/:id/actions/add_comment` - describe action
- [x] Add `POST /studios/:handle/n/:id/actions/add_comment` - execute action
- [x] Add `GET /studios/:handle/d/:id/actions/add_comment` - describe action
- [x] Add `POST /studios/:handle/d/:id/actions/add_comment` - execute action
- [x] Add `GET /studios/:handle/c/:id/actions/add_comment` - describe action
- [x] Add `POST /studios/:handle/c/:id/actions/add_comment` - execute action
- [ ] Add `GET /studios/:handle/r/:id/actions/add_comment` - describe action (representation sessions)
- [ ] Add `POST /studios/:handle/r/:id/actions/add_comment` - execute action (representation sessions)

---

## Fix Priority

### High Priority (Blocking functionality)
- [x] Heartbeat gate on studio homepage (missing feature)
- [x] `send_heartbeat` action (missing route)
- [x] Cycle detail pages (500 errors)
- [x] Add option action on decisions (500 error)
- [x] Join commitment action (404 - route missing)
- [x] `add_comment` action on notes, decisions, commitments

### Medium Priority (Missing features)
- [ ] New commitment page (406 - no markdown support)
- [ ] Representation pages (406 - no markdown support)
- [ ] User profile pages (406 - no markdown support)
- [ ] Studio join page (406 - no markdown support)
- [ ] Studio team page (empty response)

### Low Priority (Polish)
- [ ] Standardize action documentation format across all pages

---

## Integration Tests to Add

Add tests to `test/integration/markdown_ui_test.rb`. Current coverage only includes:
- Home page
- New studio page
- Studio page
- New note page
- New decision page

### Navigation Tests (GET requests)

- [ ] `GET /studios/:handle/cycles` - cycles index
- [ ] `GET /studios/:handle/cycles/today` - cycle detail (currently 500)
- [ ] `GET /studios/:handle/cycles/this-week` - cycle detail (currently 500)
- [ ] `GET /studios/:handle/commit` - new commitment (currently 406)
- [ ] `GET /studios/:handle/n/:id` - note detail
- [ ] `GET /studios/:handle/d/:id` - decision detail
- [ ] `GET /studios/:handle/c/:id` - commitment detail
- [ ] `GET /studios/:handle/r/:id` - representation (currently 406)
- [ ] `GET /studios/:handle/backlinks` - backlinks page
- [ ] `GET /studios/:handle/team` - team page (currently empty)
- [ ] `GET /studios/:handle/join` - join page (currently 406)
- [ ] `GET /studios/:handle/settings` - settings page
- [ ] `GET /u/:handle` - user profile (currently 406)

### Action Tests (POST requests)

- [ ] `POST /studios/new/actions/create_studio` - create studio
- [ ] `POST /studios/:handle/actions/send_heartbeat` - send heartbeat (currently missing)
- [ ] `POST /studios/:handle/note/actions/create_note` - create note
- [ ] `POST /studios/:handle/decide/actions/create_decision` - create decision
- [ ] `POST /studios/:handle/commit/actions/create_commitment` - create commitment
- [ ] `POST /studios/:handle/n/:id/actions/confirm_read` - confirm read
- [x] `POST /studios/:handle/d/:id/actions/add_option` - add option (fixed)
- [ ] `POST /studios/:handle/d/:id/actions/vote` - vote on decision
- [x] `POST /studios/:handle/c/:id/actions/join_commitment` - join commitment (fixed)
- [ ] `POST /studios/:handle/n/:id/actions/add_comment` - add comment to note
- [ ] `POST /studios/:handle/d/:id/actions/add_comment` - add comment to decision
- [ ] `POST /studios/:handle/c/:id/actions/add_comment` - add comment to commitment

### Heartbeat Gate Tests

- [ ] Studio homepage without heartbeat shows only `send_heartbeat` action
- [ ] Studio homepage with heartbeat shows full content
- [ ] Other studio pages require heartbeat (or redirect to homepage)

---

## Manual Testing Checklist

After fixes, verify via MCP:

- [ ] Send heartbeat on studio homepage
- [ ] Verify heartbeat gate (content hidden until heartbeat sent)
- [ ] Navigate to each cycle detail page
- [ ] Add options to a decision
- [ ] Join a commitment
- [ ] Navigate to new commitment page
- [ ] Navigate to representation pages
- [ ] Navigate to user profiles
- [ ] Navigate to studio join page
- [ ] Navigate to studio team page
