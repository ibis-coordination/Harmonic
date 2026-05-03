# Security Hotfix Deployment Postmortem (GHSA-g35v-6gwr-xpwp)

## Timeline

### 2026-05-02 (Discovery & Fix)

- **Evening:** Cross-collective automation privacy vulnerability discovered during chat feature work
- Wrote 5 failing tests demonstrating the vulnerability in `AutomationDispatcher.find_matching_rules`
- Created GitHub Security Advisory (GHSA-g35v-6gwr-xpwp) as draft
- Created temporary private fork, implemented fix on branch `fix-automation-collective-scoping`
- Fix: SQL-level collective filtering + Ruby-level `rule_has_collective_access?` redundant check
- Full test suite (3554 tests) passed in private fork

### 2026-05-03 (Deploy)

- Merged PR on private fork — unexpectedly merged into public repo (not just the private fork)
- Fix is now publicly visible before production deploy
- Attempted hotfix build workflow from `docs/DEPLOYMENT.md`
- First build used `docker compose build` which produced ARM images — pushed to registry, broke production
- Rolled back production by pulling previous images by commit SHA tag (`amd64-425821cb...`)
- Rebuilt with `docker buildx build --platform linux/amd64` — correct AMD64 images
- Deployed fix to production successfully
- Published security advisory (GHSA-g35v-6gwr-xpwp)
- Tagged release v1.11.1, CI rebuilt images
- Created deployment scripts (`deploy.sh`, `rollback.sh`, `hotfix-patch.sh`, `hotfix-build.sh`)
- Rewrote security hotfix workflow in `docs/DEPLOYMENT.md`

## Issues Encountered

### 1. Private fork merge went public

**What happened:** Merging the PR on the GitHub advisory's temporary private fork pushed the commits to the public `main` branch immediately, rather than staying within the private fork.

**Expected:** Merge stays within the private fork until the advisory is published.

**Root cause:** Unclear — GitHub's advisory fork UI may have been merging to the public repo's main branch. The target branch may not have been set correctly, or this is how GitHub's advisory forks work by default.

**Action needed:** Investigate GitHub's advisory fork merge behavior. The deployment guide should clarify this step and warn about the risk.

### 2. `docker-compose.production.yml` requires env vars for build

**What happened:** Running `docker compose -f docker-compose.production.yml -f docker-compose.build.yml build` failed because production environment variables (`REDIS_PASSWORD`, `AGENT_RUNNER_SECRET`, `HOSTNAME`) are required by the compose file even though they're not needed for building images.

**Error:** `required variable REDIS_PASSWORD is missing a value`

**Workaround:** Prefix with dummy values: `REDIS_PASSWORD=dummy AGENT_RUNNER_SECRET=dummy HOSTNAME=dummy docker compose ... build`

**Action needed:** Either:
- Add a `.env.build` file with dummy values for build-only use
- Or modify the production compose file to use `${VAR:-default}` instead of `${VAR:?error}` for variables not needed at build time
- Or create a build script that sets dummy values automatically

### 3. ARM images pushed to registry (wrong platform)

**What happened:** Building on a Mac (Apple Silicon / ARM) produced `linux/arm64` images. These were pushed to `ghcr.io` as `:latest`, overwriting the previous AMD64 images. Production server (AMD64) couldn't run them.

**Error:** `The requested image's platform (linux/arm64/v8) does not match the detected host platform (linux/amd64/v3)`

**Impact:** Production app went down. Required emergency rollback.

**Workaround:** Pulled previous images by commit SHA tag, re-tagged as `:latest`, restarted.

**Action needed:**
- The hotfix build process MUST use `docker buildx build --platform linux/amd64` (or multi-arch)
- Add a build script that enforces the correct platform
- Consider tagging with version numbers (e.g., `:v1.11.1`) in addition to `:latest` so rollback is straightforward
- The CI workflow already handles multi-arch via `docker-publish.yml` — the hotfix workflow should match

### 4. Rollback required manual digest lookup

**What happened:** After pushing bad ARM images as `:latest`, rolling back required finding the previous AMD64 image digest manually via the GitHub Packages web UI.

**Workaround:** Found images tagged by commit SHA (e.g., `amd64-425821cb...`), pulled by that tag, re-tagged as `:latest`.

**Action needed:**
- Document the rollback process explicitly
- Consider always tagging images with version numbers so rollback is `docker pull ...:v1.11.0`
- Add a rollback script

### 5. `setup.sh` references nonexistent `docker-compose.dev.yml`

**What happened:** The setup script in the private fork (and public repo) references `docker-compose.dev.yml` which doesn't exist.

**Fix applied:** Changed to `-f docker-compose.yml` only.

**Action needed:** Fix in public repo too (already committed in the security fix branch).

## Commands Run

### Local (Mac, Apple Silicon)

```bash
# WRONG — produced ARM images
docker compose -f docker-compose.production.yml -f docker-compose.build.yml build
docker compose -f docker-compose.production.yml -f docker-compose.build.yml push

# CORRECT — cross-compile for AMD64
docker buildx create --use --name multiarch 2>/dev/null || true
docker buildx build --platform linux/amd64 \
  -f Dockerfile.production \
  -t ghcr.io/ibis-coordination/harmonic:latest \
  --push .
docker buildx build --platform linux/amd64 \
  -f agent-runner/Dockerfile \
  -t ghcr.io/ibis-coordination/harmonic-agent-runner:latest \
  --push ./agent-runner
```

### Production server

```bash
# Emergency rollback
docker pull ghcr.io/ibis-coordination/harmonic:amd64-425821cb7f12d627e6c66ededc793b69f5829d0e
docker pull ghcr.io/ibis-coordination/harmonic-agent-runner:amd64-425821cb7f12d627e6c66ededc793b69f5829d0e
docker tag ghcr.io/ibis-coordination/harmonic:amd64-425821cb7f12d627e6c66ededc793b69f5829d0e ghcr.io/ibis-coordination/harmonic:latest
docker tag ghcr.io/ibis-coordination/harmonic-agent-runner:amd64-425821cb7f12d627e6c66ededc793b69f5829d0e ghcr.io/ibis-coordination/harmonic-agent-runner:latest
docker compose -f docker-compose.production.yml up -d

# Deploy new version (after correct AMD64 images are pushed)
docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml up -d
```

## Action Items

### Immediate

- [x] Publish the security advisory once deploy is verified
- [x] Tag release `v1.11.1` on public repo

### Process fixes

- [x] Fix `setup.sh` in public repo (remove `docker-compose.dev.yml` reference)
- [x] Create `scripts/hotfix-build.sh` that enforces `--platform linux/amd64` and sets dummy env vars
- [x] Create `scripts/rollback.sh` that accepts a version tag or commit SHA
- [x] Update `docs/DEPLOYMENT.md` hotfix workflow with platform warnings and rollback steps
- [x] Clarify GitHub advisory fork merge behavior in docs
- [x] Tag images with version numbers — CI already does this via `type=semver` when triggered by git tags
- [x] Create `scripts/hotfix-patch.sh` for emergency file-level patching (seconds, no build)
- [x] Document three deployment paths (patch/CI/local build) in order of speed

### Build speed (future)

- [x] Default hotfix path documented as "tag and let CI build" (~5 min on native AMD64)
- [ ] Add registry-based buildx layer caching (`--cache-from`/`--cache-to`) to reduce local rebuild time
- [ ] Create a `Dockerfile.base` / `harmonic-base` image with pre-installed dependencies. App image then only copies code and precompiles assets (~1-2 min even under QEMU)
