# Running tests locally

## Rails test suite (Docker)

The Rails test suite runs in Docker via a trimmed, CI-faithful compose file
([`docker-compose.test.yml`](../docker-compose.test.yml)) — just a test runner
plus Postgres and Redis, matching the versions and environment used in CI.

```bash
docker compose -f docker-compose.test.yml build
docker compose -f docker-compose.test.yml run --rm test                                   # full suite
docker compose -f docker-compose.test.yml run --rm test bundle exec rails test test/models  # a subset
docker compose -f docker-compose.test.yml down -v                                         # tear down
```

The image bakes the app code, gems and assets, so rebuild after changing code.

## TypeScript / JavaScript tests (no Docker)

The TS tests are plain Node (v22) and need no Postgres, Redis, or containers —
they run natively in seconds. This mirrors CI's separate `typescript` job, which
covers three independent packages:

```bash
# Frontend UI (root package.json) — Stimulus controllers etc., vitest + jsdom
npm install
npm run typecheck      # tsc --noEmit
npm test               # vitest run  (app/javascript/**/*.test.ts)
npm run build          # esbuild bundle

# agent-runner (vitest)
cd agent-runner && npm install && npm run build && npm run typecheck && npm test

# harmonic-bridge (node's built-in --test runner)
cd harmonic-bridge && npm install && npm run typecheck && npm test && npm run build
```

So frontend Stimulus work, `agent-runner`, and `harmonic-bridge` need neither
Docker nor a database — just Node and disk for `node_modules`.

## End-to-end tests (Playwright)

Playwright e2e is the one TS surface that needs a **running app** — it drives a
real Chromium against the stack (web + db + redis up), reachable at
`E2E_BASE_URL` (default `https://app.harmonic.local`) with the authed storage
state from [`e2e/global-setup.ts`](../e2e/global-setup.ts).

```bash
npm run playwright:install   # one-time: install the Chromium browser
npm run test:e2e             # playwright test  (needs the app running)
```

CI does **not** run Playwright in the `typescript` job — it's for local/manual use.
