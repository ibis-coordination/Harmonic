# Harmonic App Navigation Skill

Comprehensive guide to navigating the Harmonic application in the browser.

## App Concepts

Harmonic is a social agency platform built around the OODA loop:

| Model | OODA Phase | Purpose |
|-------|------------|---------|
| Note | Observe | Posts/content for sharing observations |
| Decision | Decide | Group decisions via acceptance voting |
| Commitment | Act | Action pledges with critical mass thresholds |
| Cycle | Orient | Time-bounded activity windows |
| Link | Orient | Bidirectional references between content |

## URL Structure

### Global Routes (work without studio context)

| Path | Purpose |
|------|---------|
| `/` | Home page - lists studios and scenes |
| `/login` | Login page (honor_system auth) |
| `/studios` | List all studios user belongs to |
| `/studios/new` | Create new studio form |
| `/scenes` | List all public scenes |
| `/scenes/new` | Create new scene form |
| `/note` | Create note (global) |
| `/decide` | Create decision (global) |
| `/commit` | Create commitment (global) |
| `/notifications` | User notifications |
| `/actions` | List all available MCP actions |

### Studio-Scoped Routes

| Path | Purpose |
|------|---------|
| `/studios/{handle}` | Studio home page |
| `/studios/{handle}/note` | Create note in studio |
| `/studios/{handle}/decide` | Create decision in studio |
| `/studios/{handle}/commit` | Create commitment in studio |
| `/studios/{handle}/n/{id}` | View note (8-char truncated ID) |
| `/studios/{handle}/d/{id}` | View decision |
| `/studios/{handle}/c/{id}` | View commitment |
| `/studios/{handle}/cycles` | Cycle overview with counts |
| `/studios/{handle}/cycles/today` | Today's items |
| `/studios/{handle}/cycles/yesterday` | Yesterday's items |
| `/studios/{handle}/cycles/tomorrow` | Tomorrow's items |
| `/studios/{handle}/cycles/this-week` | This week's items |
| `/studios/{handle}/cycles/last-week` | Last week's items |
| `/studios/{handle}/cycles/next-week` | Next week's items |
| `/studios/{handle}/cycles/this-month` | This month's items |
| `/studios/{handle}/backlinks` | Items sorted by backlink count |
| `/studios/{handle}/team` | Studio team members |
| `/studios/{handle}/settings` | Studio settings |
| `/studios/{handle}/join` | Join studio (if invited) |

### User Routes

| Path | Purpose |
|------|---------|
| `/u/{handle}` | User profile |
| `/u/{handle}/settings` | User settings |
| `/u/{handle}/settings/subagents/new` | Create subagent |
| `/u/{handle}/settings/tokens/new` | Create API token |

## Key UI Elements

### Navigation Bar
- Shows current location (Home, Studio name)
- Shows logged-in user with link to profile
- Shows notification count with link to notifications

### Home Page Structure
- **Your Scenes** - Public groups (scenes)
- **Your Studios** - Private groups (studios)
- **Other Subdomains** - Links to other tenants

### Studio Page Structure
- **Explore** section with links to Cycles and Backlinks
- **Pinned** section for pinned items
- **Team** section showing members and subagents
- **Actions** section with New Note/Decision/Commitment

## Heartbeat Requirement

Studios require a "heartbeat" to access content for the current cycle:
- First visit to a studio shows "Heartbeat Required" message
- Must call `send_heartbeat()` action to gain access
- Heartbeats signal presence/engagement for the cycle

## Content Creation

### Notes
- Require only text content (markdown)
- Support @mentions (e.g., `@username`)
- Can have file attachments
- Actions: `confirm_read()`, `add_comment(text)`

### Decisions
- Require: question, options_open (boolean), deadline
- Optional: description (markdown)
- Two-phase voting: Accept (filter) then Prefer (select)
- Results sorted by: acceptance, then preference, then random
- Actions: `add_option(title)`, `vote(option_title, accept, prefer)`, `add_comment(text)`

### Commitments
- Require: title, critical_mass, deadline
- Optional: description (markdown)
- Show progress bar toward critical mass
- Actions: `join_commitment()`, `add_comment(text)`

## Cycles

Content is organized into time-bounded cycles:
- **Daily**: yesterday, today, tomorrow
- **Weekly**: last week, this week, next week
- **Monthly**: last month, this month, next month

Items appear in cycles if their time window overlaps with the cycle.

## Common Gotchas

### Form Selection
Hidden logout form exists on most pages. Use specific selectors:
```typescript
// Use specific form actions
page.locator('form[action="/note"]')
page.locator('form[action="/decide"]')
page.locator('form[action="/commit"]')
```

### Route Collision
`/studios/new` is a valid route for creating studios. Don't append content paths to it:
- `/studios/new/note` - WRONG (interprets "new" as studio handle)
- `/note` - CORRECT (use global route)

### Turbo Drive
The app uses Turbo Drive which intercepts navigation:
- Direct navigation may not trigger full page loads
- Cookie clearing alone may not log out user
- Always navigate explicitly after auth state changes

### Subdomain Multi-tenancy
Each subdomain is a separate tenant:
- `app.harmonic.local` - primary tenant
- `second.harmonic.local` - another tenant
- Studios exist within a single tenant

## Browser Testing Tips

1. **Wait for content, not URLs**: Content loading may lag behind URL changes
2. **Use specific selectors**: Avoid generic `form` or `button` selectors
3. **Check for heartbeat**: First studio access may require sending heartbeat
4. **Handle optional content**: Use `.count() > 0` checks before interacting
5. **Clear all storage on logout**: Cookies, localStorage, and sessionStorage
