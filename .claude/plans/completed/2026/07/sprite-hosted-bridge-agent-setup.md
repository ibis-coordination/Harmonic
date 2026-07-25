# Sprite-hosted bridge agents: one-script setup for user-owned external agents

**Status: shipped.** PRs #526/#527 (bridge 0.2.1 `setup-sprite`), hardened through bridge 0.2.2/0.2.3 (PRs #528/#529); verified end-to-end on a live sprite 2026-07-24.

## Goal

Make it as easy as possible for a Harmonic user to spin up their own external agent — one that can do ~anything an external agent can do (shell, files, web, own LLM credentials) — on infrastructure **they** own and control. The user signs up for Fly.io Sprites, runs `sprite org auth`, then runs one script with a Harmonic bridge-setup URL. Everything else is automated, reusing the existing harmonic-bridge credential-exchange flow.

Harmonic hosts nothing and holds no Fly credentials. This is onboarding tooling around already-shipped machinery (external agents + harmonic-bridge + bridge-setup connect flow), not a hosting product. The external-runtime invariants apply unchanged: user brings their own LLM credentials, no pool-funding guarantee, `/mcp` is the audited boundary.

Sprites is the *recommended easiest host*, not a dependency — the same script shape works on any Linux box with the tunnel steps retained (see `setup-bridge-agent-on-fresh-vm.md` for the generic VPS runbook this supersedes as the blessed path).

## Verified constraints (docs.sprites.dev, checked 2026-07-23)

The three facts the design hinges on, all confirmed:

1. **Public ingress** — every sprite gets `https://<name>-<org-id>.sprites.app`. Default is org-private; `sprite url update` (or `sprite config update --url-auth public`) flips it public. Wake-on-request: ~100–500ms warm, 1–2s cold start. Docs explicitly name webhooks as an intended use of public mode. Harmonic's `WebhookDeliveryService` can POST to it directly — **no Cloudflare tunnel, no DNS, no domain.**
2. **Process-on-wake** — "Services" (`sprite-env services create <name> --cmd <bin> --args <args>`) auto-restart whenever the sprite wakes. HTTP routes to **port 8080 by default** — which is harmonic-bridge's default listen port. The Service replaces the systemd unit.
3. **Interactive exec** — `sprite console` opens an interactive TTY; `sprite exec` supports TTY allocation, env vars, and file uploads. The one-time `claude login` URL-paste flow works mid-script with the user at their terminal.

Also confirmed:
- Base image is a dev environment: Node.js, Python, Go, Git preinstalled — no NodeSource step needed.
- CLI install: `curl -fsSL https://sprites.dev/install.sh | sh`; auth: `sprite org auth` (browser flow via Fly.io).
- Filesystem persists across hibernation (100 GB); running processes and RAM do not. TTY sessions die on sleep; Services restart on wake.
- Sleep trigger: sprite stays awake during active exec/console, open TCP connections, TTY sessions, or Services with connections; sleeps when all activity ceases.
- Checkpoints: `sprite checkpoint create/restore` — full state snapshots, user-facing undo.
- `sprite auth setup` exists for non-interactive token setup (future CI/scripted paths).

### Constraints that shape the design

- **Public URL is internet-exposed; auth is the bridge's webhook HMAC.** Same posture as the current tunnel-based runbook (tunnel hostname is equally public). The daemon must keep rejecting unsigned/mis-signed POSTs — already its behavior; re-verify in prototype.
- **RAM loss on hibernation** means the daemon must be stateless between events (it is) and the Claude OAuth session must live on disk (it does, `~/.claude/`).
- **Mid-task hibernation risk (open question #1)**: a `claude` subprocess between LLM calls may briefly have no open TCP connection. Does the sprite count an in-flight webhook response / active service child process as activity? Must verify in prototype with a long multi-minute task. Mitigation if needed: daemon holds the inbound webhook connection open for the task duration (it may already), or a keepalive ping.
- **Pricing/plan (open question #2)**: subscription tiers gate concurrently-awake sprites (~$20/mo entry, 20 awake). Unclear whether a free tier covers a single mostly-idle sprite. Affects the "sign up for Fly" instruction copy, nothing structural.

## Architecture

```
User's laptop                    User's sprite (their Fly account)        Harmonic
  sprite CLI (authed)              harmonic-bridge daemon :8080            bridge-setup connect flow
  setup script ──sprite exec──►    claude code + MCP wiring         ◄────  webhook POSTs to
                                   Service: auto-restart on wake            https://<sprite>.sprites.app
                                                                            /mcp for all agent actions
```

- The **script runs on the user's laptop**, where the sprite CLI is authenticated; it drives the sprite remotely via `sprite exec` / `sprite console`.
- The **sprite runs exactly what the VPS runbook installs**, minus cloudflared and systemd: harmonic-bridge daemon (as a Service), Claude Code, per-agent MCP config.
- **Harmonic side is unchanged at the protocol level**: `harmonic-bridge add --from <bridge-setup-URL>` performs the existing credential exchange; the webhook registration uses the sprite's public URL as `public_url`.

## Work breakdown

### Phase 0 — Manual prototype (an afternoon, personal Fly account)

Run the VPS runbook by hand against a sprite, adapting as needed. Verification checklist:

- [ ] `sprite create` → base image contents (node version, npm -g permissions)
- [ ] `npm i -g @ibis-coordination/harmonic-bridge @anthropic-ai/claude-code` works
- [ ] `harmonic-bridge init` + config with `public_url` = sprite URL; daemon runs as a Service; survives hibernate/wake (POST after a forced sleep → daemon answers)
- [ ] URL flipped public; unsigned POST rejected (405/401), signed test webhook accepted
- [ ] `claude login` via `sprite console`; OAuth session survives hibernation; `claude -p 'ok'` after wake
- [ ] End-to-end: chat message on Harmonic → webhook → wake → claude runs → reply lands (measure wake-to-reply latency)
- [ ] **Long task test**: multi-minute agent task; confirm sprite does not hibernate mid-task
- [ ] Checkpoint before/after setup; restore works (candidate user-facing "reset my agent" story)
- [ ] Note actual plan/pricing requirements encountered at signup

Output: corrections to this plan + a raw command transcript that becomes the script.

#### Phase 0 findings (2026-07-23, sprite `harmonic-bridge-proto` on Dan's account)

Confirmed working end-to-end up to the interactive steps:

- **REST API exists**: `api.sprites.dev/v1/sprites` (create, status; `sprite api <path>` wraps it). Status values observed: `running` → `warm` (~1 min after activity stops).
- **Base image**: Ubuntu 26.04, Node 24 (nvm-managed), git, non-root user `sprite` — **and Claude Code preinstalled** at `~/.local/bin/claude`. npm-g re-install of claude-code is unnecessary (and its postinstall is blocked by npm `allow-scripts` policy anyway).
- **npm -g gotcha**: global bin dir (`$(npm prefix -g)/bin`, nvm-managed) is NOT on PATH for `sprite exec` or login shells. Fix: `ln -sf $(npm prefix -g)/bin/harmonic-bridge ~/.local/bin/` (already on PATH). The script must do this.
- **`sprite exec` takes literal argv** (`sprite exec -s <name> -- sh -c "..."` for shell strings), no shell interpretation.
- **Service**: `sprite-env services create harmonic-bridge --cmd /home/sprite/.local/bin/harmonic-bridge` (run *inside* the sprite) starts the daemon and persists it; logs at `/.sprite/logs/services/harmonic-bridge.log`. Daemon bound to `127.0.0.1:8080` is reachable through the sprite URL — loopback binding works, no 0.0.0.0 needed.
- **URL auth**: default is `sprite` (org-only; external requests get a 302 auth redirect). `sprite url update -s <name> --auth public` flips it. After that, external GET `/webhook/probe` → 405 (daemon rejecting GET, correct) and POST to unknown handle → 404.
- **Wake latency measured**: 188ms total for an external POST against a `warm` sprite (incl. TLS from laptop); daemon process survived the warm transition without restart. Cold-state wake + service-restart still to be measured.

**End-to-end test PASSED** (agent `biz` on sandbox.harmonic.social): chat message → webhook (204) → wake → Claude Code ran ~4 min (first wake incl. MCP handshake) → reply landed in Harmonic chat via execute_action. Harmonic's synchronous registration-verification POST also passed against the sprite URL. Additional findings:

- **`sprite file push/pull`** is the clean way to write config into a sprite from the orchestrating laptop — use it in the script instead of heredocs-through-exec.
- **System-prompt bug inherited from the VPS runbook**: `harmonic://context` is an MCP *resource* (`resources/read`), NOT a valid `fetch_page` path — fetch_page only accepts in-tenant `/` paths and rejects it. Corrected to `fetch_page /whoami` in both the runbook and the sprite. The Phase 1 harness preset must ship the corrected prompt.
- **Personal-account carryover**: `claude login` with a personal claude.ai account brings that account's connector config (Gmail/Calendar/Drive listed, unauthorized) onto the agent machine. Harmless unauthorized, but the docs should recommend a dedicated Claude account for hosted agents, or at least name the implication.
- **Checkpoint created** (v1) of the fully-configured state. Quirk: `checkpoint list` shows v1 with a timestamp predating its creation — display bug or base-image time; don't trust the list timestamps, trust the comment field.
- npm claude-code must NOT be installed — its blocked postinstall leaves a broken `claude` shadowing the image's preinstalled working one (hit this; uninstalled).

**CRITICAL FINDING — freeze semantics (2026-07-23 evening):** Sprites freeze within ~1 second of the last connection/exec-session closing, and **local CPU activity does not count as activity** — a runnable process (claude mid-startup) was frozen 1s after the observing exec session closed (API timestamps: `last_running 21:58:03`, `last_warming 21:58:04`). Consequences observed live:

- Webhook wakes fail in practice despite 204 delivery success: the daemon 204s in ~200ms, the connection closes, and the machine freezes before the spawned `claude` opens its first API connection (~1s into a multi-second startup). The task is paused (not killed) and resumes losslessly on the next wake — but "next wake" may be minutes/hours away.
- The first successful e2e run was an observer effect: concurrent diagnostic `sprite exec` sessions were keeping the machine awake.
- Established outbound connections DO count (claude's API streaming kept the first run alive between local tool calls) — the danger windows are (a) post-204 harness startup and (b) long local tool executions with no open socket (`sleep`, builds, big clones).

**Required mitigation (Phase 1, harmonic-bridge feature):** while any wake_command child is running, the daemon holds an open connection — a hanging request to its own public URL is self-contained — releasing it when the child exits. Config flag (e.g. `hold_awake_during_wake: true`), enabled by the sprite setup path. Preserves the hibernation economics: awake exactly during tasks. Without this feature the sprite path does not work; it is a Phase 1 prerequisite, not polish.

**Freeze/thaw is NOT lossless for network state.** A wake that was frozen mid-startup and later thawed completed its local work (sleep timing exact, uptime continuous) but its MCP client transport never finished connecting — in-flight connections/timers break across thaw (the endpoint itself was healthy; the agent fell back to raw `curl` against `/mcp` and still delivered its reply). So frozen tasks resume, but any socket or timeout that was open at freeze time is suspect afterward. This is the second independent reason `hold_awake_during_wake` is mandatory: it prevents freezes from ever landing inside an active wake.

**Hold-awake SHIPPED and ACCEPTED (harmonic-bridge 0.2.1, 2026-07-23 night).** Two-part fix, both required:

1. `hold_awake_during_wake` — refcounted client holding a hairpin request to `${public_url}/hold` (heartbeat-streaming route, off by default, 16-connection cap) for the duration of every wake.
2. **Ack delay (`beforeAck` + `prime()`)** — hold establishment (~0.5s DNS+TLS through the edge) races the ~1s freeze, and lost at least once in testing. The server now acquires the hold and waits for its first heartbeat *before* writing the 204 (2s cap, 10s auto-release grace bridging to the wake's own acquire). While Harmonic's POST is open the machine can't freeze, so there is no unheld instant. Measured ack: 0.65s vs 0.19s pre-fix — well inside Harmonic's 30s delivery timeout.

Unattended acceptance test PASSED: synthetic signed webhook → wake → claude ran `sleep 120` as a *detached background task* (the agent's own hardening of the test) → uptime advanced continuously, no suspend gap → reply posted via MCP tools (transport healthy when no mid-startup freeze occurs, further confirming the thaw-breaks-sockets finding). Machine: running 23:37:35→23:40:14, warm after — awake exactly for the task.

Observability gap for Phase 1: the daemon discards `SpawnResult` (exit code, timedOut) and claude's errors land on stdout, so a wake that dies pre-reply is invisible in the service log. Log per-wake start/exit-code lines. Also: hold failures now log to stderr (first + every 40th).

**Cold-wake measurements (2026-07-24 00:19Z, after ~40 min idle → status `cold`; the cold state nulls the API's last_running/last_warming fields):**

- Cold GET through the edge: **405 in 1.77s** — VM boot + Service auto-restart of the daemon + request served. Warm comparison: 0.16s. Matches the docs' 1–2s claim.
- Claude auth dir, agent secrets, and the Service definition all survived deep cold; service came back `running` unaided.

**Checkpoint restore is BROKEN (platform bug, 2026-07-24):** `checkpoint create` works (v1, v2), but `restore v1` fails twice with `BackupActiveCheckpoint failed: JuiceFS rename clone: … v3.in-progress → v3: file exists` — a stale server-side artifact. Live state was untouched by the failed attempts. Also the checkpoint list timestamps are visibly wrong (v2 displays v1's creation time). Conclusion: treat checkpoints as best-effort backup only; do NOT build a user-facing "reset your agent" story on restore until the platform matures. Worth a Fly community report.

**Phase 1 bridge-side work: DONE and committed** on branch `harmonic-bridge-hold-awake` (Harmonic repo, harmonic-bridge/):
- `8f9990d9` hold_awake_during_wake + ack-delay (0.2.1)
- `c6b38e2f` per-wake spawn/exit logging
- claude-code-harness built-in (opt-in named step; default after_add stays empty)
- `setup-sprite` command — **harness-specific logic requires an explicit `--harness` flag** (decision 2026-07-23): without it, no harness is assumed, the stub wake_command stays, and manual wiring instructions print. `claude-code` is the first registry entry. Single-use --from URL is never touched laptop-side (tested).

Remaining: Fly community report on the restore bug. DONE since: 0.2.1 published to npm (after npm-11 Trusted Publishing fix), Phase 2 Rails shipped in PR #527 (Sprites listed second, framed neutrally, Sprites CLI setup deferred to docs.sprites.dev), 1.56.0 release chore on main. Pricing note (open Q2) DROPPED: stating Fly's prices in Harmonic copy advertises their product and rots when their pricing changes — the docs.sprites.dev link covers it.

### Phase 1 — Script + harness preset (harmonic-bridge repo)

- New subcommand: `harmonic-bridge setup-sprite --from <bridge-setup-URL>` (runs on the laptop via npx; the package is already published, so `npx @ibis-coordination/harmonic-bridge setup-sprite --from …` needs no prior install).
  - Preflight: sprite CLI installed + authed; bridge-setup URL reachable; agent has no existing webhook.
  - Steps: create sprite (named after agent handle) → install packages in-sprite → init + write config (public_url from `sprite url`) → flip URL public → interactive `claude login` handoff → run `add --from` in-sprite → write harness preset → create Service → smoke test (signed probe + instructions to send a chat message).
  - Idempotent: every step checks before acting; re-running repairs a partial setup.
- **Harness preset** to eliminate the runbook's step-9 heredocs: `harmonic-bridge add --harness claude-code` (or an `after_add` built-in) that writes the wake_command and a default system prompt template. This benefits *all* bridge installs, not just sprites — the VPS runbook shrinks too.
- Tests per that repo's conventions; the sprite-CLI interactions need a thin wrapper injectable for testing.

### Phase 2 — Harmonic side (this repo, small)

- Bridge-setup show page (`bridge_setups#show`): add the Sprites path as the recommended option — three copy-paste blocks (install CLI, `sprite org auth`, `npx … setup-sprite --from <url>`), with the generic-host instructions retained below.
- Help docs: new or updated `/help` page for self-hosting an agent on Sprites; audience-neutral per help-page conventions (agents read these too).
- No new models, controllers, or trust decisions. Confirm `WebhookDeliveryService` SSRF filter permits `*.sprites.app` (it should — public IPs — but check).

### Phase 3 — Later / optional

- `harmonic-bridge doctor` for remote support-over-docs (checks daemon, service, URL auth, webhook registration, claude auth).
- Alternate harness presets (model-agnostic option for non-Claude users).
- `sprite auth setup` non-interactive path for power users / CI.
- Revisit platform-hosted sprites only if demand data from this shows the Fly-account signup step is the bottleneck.

## Open questions

1. Mid-task hibernation: does sustained `claude` work (with gaps between API calls) keep the sprite awake? (Phase 0 test; mitigation identified above.)
2. ~~Sprites pricing floor for a single mostly-idle sprite~~ — dropped 2026-07-23: Harmonic copy never states Fly's prices (third-party neutrality; rots when their pricing changes). Link docs.sprites.dev instead.
3. Should the sprite be named after the agent handle (`harmonic-<handle>`) or user-chosen? (Leaning fixed derivation — simpler support story; the URL embeds it.)

## Answered questions (2026-07-23)

- **Webhook registration order** (was open Q4): `harmonic-bridge add` validates `public_url` in daemon config *before* redeeming the setup URL (`src/add.ts` `validatePublicUrl`), and Harmonic sends a synchronous verification POST to the webhook URL during registration — so the daemon must be running and publicly reachable at `add` time. Script order is therefore: write config with sprite URL → start daemon Service → flip URL public → `add --from`. Also: the setup URL is redeemed by **POST and is single-use** — preflight must never POST it to check validity.
- **SSRF filter**: both `WebhookDeliveryService` (ongoing delivery) and `WebhookTestDelivery` (registration-time verification, `harmonic_bridge_setups_controller.rb`) use `SsrfFilter.post` with default policy — public hosts allowed, so `*.sprites.app` works with zero Rails changes. Verification timeout is 30s, comfortably above the 1–2s cold-wake latency.
- **CLI maturity**: installed CLI is `v0.0.1-rc46` (installs to `~/.local/bin`, no sudo). Release-candidate versioning — expect churn; the setup script should tolerate CLI output-format changes (prefer `sprite api`/JSON where available over parsing human output).

## Key references

- `setup-bridge-agent-on-fresh-vm.md` / `.sh` — the generic VPS runbook this adapts
- [Sprites quickstart](https://docs.sprites.dev/quickstart/), [Working with Sprites](https://docs.sprites.dev/working-with-sprites/), [CLI reference](https://docs.sprites.dev/cli/commands/)
- harmonic-bridge: `add --from` credential exchange, `after_add` hooks, daemon webhook HMAC verification
- Rails: `bridge_setups` controller/views, `WebhookDeliveryService` (SSRF filter), `/help` pages
