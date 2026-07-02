# Running tests locally

## Rails tests (Docker)

Run **targeted subsets** locally, not the whole suite — the full suite is slow
everywhere and CI owns it. There are two compose files, for two different jobs:

- [`docker-compose.dev.yml`](../docker-compose.dev.yml) — the **fast iterate
  loop**. It bind-mounts your working tree, so you edit a `.rb` file and re-run a
  targeted test with **no rebuild**. This is the day-to-day one.
- [`docker-compose.test.yml`](../docker-compose.test.yml) — **reproduces CI
  exactly** (bakes the code into the image the way the Dockerfile and CI do).
  Reach for it only to confirm "does this behave the same as CI"; it needs a
  rebuild after every code change.

### Fast loop — `docker-compose.dev.yml`

One-time setup (Postgres + Redis stay up across runs):

```bash
docker compose -f docker-compose.dev.yml up -d db redis
docker compose -f docker-compose.dev.yml run --rm dev bin/rails db:test:prepare
```

Then iterate — edit code and re-run a targeted subset, no rebuild, no re-prepare:

```bash
docker compose -f docker-compose.dev.yml run --rm dev bin/rails test test/models/user_test.rb
docker compose -f docker-compose.dev.yml run --rm dev bin/rails test test/models -n /handle/
docker compose -f docker-compose.dev.yml run --rm dev bash        # a shell in the stack
```

The working tree is live-mounted, so any `app/` or `test/` edit is picked up
immediately. Rebuild only when `Gemfile.lock` or `package.json` changes:

```bash
docker compose -f docker-compose.dev.yml build
docker compose -f docker-compose.dev.yml down -v   # refresh the dep + db volumes
```

### CI-faithful — `docker-compose.test.yml`

```bash
docker compose -f docker-compose.test.yml build
docker compose -f docker-compose.test.yml run --rm test bash -c "bin/rails db:prepare && bundle exec rails test test/models"
docker compose -f docker-compose.test.yml down -v   # tear down + drop the db volume
```

The image bakes the app code, gems and assets, so rebuild after changing code —
that's the price of matching CI's fresh-checkout build exactly.

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
