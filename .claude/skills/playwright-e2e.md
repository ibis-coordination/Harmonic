# Playwright E2E Testing Skill

Gotchas for writing and running Playwright E2E tests in Harmonic. Test files live in `e2e/tests/**/*.spec.ts`; the fixtures and helpers in `e2e/fixtures/` and `e2e/helpers/` are the reference for auth and URL patterns.

## Running

- One-time setup: `docker compose exec web bundle exec rake e2e:setup` creates the test user's email/password identity; `npm run playwright:install` installs browsers.
- `./scripts/run-e2e.sh` runs the suite with an app-health check. Direct npm scripts: `npm run test:e2e` (add `:ui`, `:headed`, or `:debug`; pass a spec path to run one file).
- Base URL comes from `E2E_BASE_URL` (default `https://app.harmonic.local` — subdomain tenancy, never localhost). Self-signed Caddy certs are handled by `ignoreHTTPSErrors` in the config; use `https://`.

## Auth

- Prefer the `authenticatedPage` fixture from `e2e/fixtures/test-fixtures.ts` — it logs in a unique test user per test. Manual `login`/`logout` helpers are in `e2e/helpers/auth.ts`.
- Logout: clearing cookies and reloading is NOT reliable (Turbo Drive can show cached logged-in state). Clear cookies + storage, then navigate explicitly to `/login`, and assert the login form is visible. The `logout` helper does this — use it.

## Selectors

- Pages contain a logout form in the user menu, so bare `page.locator("form")` over-matches. Select forms by action: `form[action="/note"]`, `form[action="/decide"]`, etc.
- Wait for visible content (`expect(locator).toBeVisible()`), not URLs — Turbo navigation makes URL waits flaky.
