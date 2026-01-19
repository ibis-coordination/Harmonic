# Playwright E2E Testing Skill

Guidelines for writing and running Playwright E2E tests in the Harmonic application.

## Running E2E Tests

**Prerequisites:**
- App must be running with `AUTH_MODE=honor_system` in `.env`
- After changing AUTH_MODE, restart the web container: `docker compose up -d web`

**Commands:**
```bash
# Run all E2E tests
npm run test:e2e

# Run with Playwright UI (interactive debugging)
npm run test:e2e:ui

# Run headed (see browser)
npm run test:e2e:headed

# Run specific test file
npm run test:e2e -- e2e/tests/auth/login.spec.ts

# Install browsers (first time setup)
npm run playwright:install
```

## URL Patterns

The app uses these URL patterns for content creation and viewing:

| Action | URL | Notes |
|--------|-----|-------|
| Create Note | `/note` | Global route, works without studio context |
| Create Decision | `/decide` | Global route, works without studio context |
| Create Commitment | `/commit` | Global route, works without studio context |
| View Note | `/n/{id}` | Truncated ID, 8 characters |
| View Decision | `/d/{id}` | Truncated ID, 8 characters |
| View Commitment | `/c/{id}` | Truncated ID, 8 characters |
| Studios List | `/studios` | Lists all studios user belongs to |
| Studio Page | `/studios/{handle}` | Show specific studio |

**Important:** Routes like `/studios/{handle}/note` also work, but avoid navigating to `/studios/new/note` - "new" gets interpreted as a superagent handle.

## Form Selection Gotchas

The app includes a hidden logout form on most pages (`<form action="/logout">`). When selecting forms, be specific:

```typescript
// BAD - matches both logout form and content form
await page.locator("form")

// GOOD - select the specific content form
await page.locator('form[action="/note"]')
await page.locator('form[action="/decide"]')
await page.locator('form[action="/commit"]')
```

## Authentication Helpers

The test fixtures provide:

```typescript
// Use authenticatedPage for tests that need logged-in state
test("my test", async ({ authenticatedPage }) => {
  // Already logged in with unique test user
})

// Use testUser to get user info
test("my test", async ({ authenticatedPage, testUser }) => {
  expect(testUser.email).toContain("e2e-test")
})

// Manual login/logout
import { login, logout, buildBaseUrl } from "../../helpers/auth"

await login(page, { email: "test@example.com", name: "Test User" })
await logout(page)  // Clears cookies and reloads
```

## Logout Behavior

The app uses Turbo Drive which intercepts navigation. The logout helper clears cookies instead of navigating:

```typescript
export async function logout(page: Page): Promise<void> {
  await page.context().clearCookies()
  await page.reload({ waitUntil: "networkidle" })
}
```

After logout, verify logged-out state by checking for login button:

```typescript
const loginButton = page.locator('button:has-text("Log in"), a:has-text("Log in")')
await expect(loginButton.first()).toBeVisible()
```

## Environment Variables

E2E tests use these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `E2E_BASE_URL` | `https://app.harmonic.local` | Full base URL |
| `E2E_HOSTNAME` | `harmonic.local` | Base hostname |
| `E2E_PORT` | (empty) | Port if non-standard |
| `E2E_PROTOCOL` | `https` | Protocol (http/https) |

## Test Organization

```
e2e/
├── global-setup.ts          # Verifies app is running
├── fixtures/
│   └── test-fixtures.ts     # Extended test with auth fixtures
├── helpers/
│   ├── auth.ts              # Login/logout helpers
│   └── tenant.ts            # Subdomain URL helpers
└── tests/
    ├── auth/                # Authentication tests
    ├── notes/               # Note creation/viewing tests
    ├── decisions/           # Decision voting tests
    ├── commitments/         # Commitment join tests
    └── studios/             # Studio navigation tests
```

## Common Patterns

### Wait for Page Content
```typescript
// Wait for specific content (more reliable than URL)
await expect(page.locator('h1:has-text("Title")')).toBeVisible()
```

### Handle Optional Elements
```typescript
const link = page.locator('a[href*="/n/"]').first()
if ((await link.count()) > 0) {
  await link.click()
  // ... continue test
}
```

### Navigate Within Studio
```typescript
// Get current URL and append path
const currentUrl = page.url()
await page.goto(currentUrl.replace(/\/$/, "") + "/cycles")
```

## SSL/HTTPS Notes

- Playwright config has `ignoreHTTPSErrors: true` for self-signed Caddy certs
- Global setup temporarily disables `NODE_TLS_REJECT_UNAUTHORIZED` for healthcheck
- All URLs should use `https://` protocol (Caddy handles SSL)
