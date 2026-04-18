# Agent Runner

The agent-runner is a Node.js service that executes AI agent tasks. It replaces the Sidekiq-based `AgentQueueProcessorJob` + `AgentNavigator` with an async model (Effect.js fibers) that handles hundreds of concurrent tasks in a single process.

## Why a separate service?

Each agent task makes 10-30+ LLM calls, each blocking for 5-60 seconds. Ruby/Sidekiq dedicates a thread per task, limiting concurrency to the Sidekiq thread count (5 by default). Node.js `await` is non-blocking — a single process handles hundreds of concurrent tasks with ~200-500 MB total memory.

## Architecture

```
Rails app                              agent-runner (Node.js)
  |                                        |
  |  AiAgentTaskRun created                |
  |  AgentRunnerDispatchService            |
  |    validates billing/status            |
  |    encrypts token (AES-256-GCM)        |
  |    publishes to Redis Stream           |
  |                                        |
  |  ── Redis Stream (XADD) ──────────►   |  picks up task (XREADGROUP)
  |                                        |  decrypts token
  |                                        |  preflight check (billing/status)
  |                                        |  claims task (mark running)
  |                                        |
  |  ◄── GET /whoami ──────────────────    |  navigate (Bearer token, Host header)
  |      (ApplicationController)           |  goes through normal auth + tenant scoping
  |  ── markdown response ──────────►      |
  |                                        |  LLM call → tool calls → navigate/execute → repeat
  |  ◄── POST /internal/.../step ──────    |  report steps incrementally (HMAC signed)
  |      (Internal::BaseController)        |
  |                                        |
  |  ◄── POST /internal/.../complete ──    |  report final result (authoritative write)
  |                                        |
  |  AiAgentTaskRun updated                |
  |  (status: completed/failed)            |
```

## Two types of HTTP request

Agent-runner makes two fundamentally different types of request to Rails:

### Agent API requests (navigate, execute_action)

The agent acting as a user. Goes through `ApplicationController`:
- Auth: `Authorization: Bearer {token}`
- Tenant: `Host: {subdomain}.{hostname}` header
- Subject to capability checks, API authorization, rate limits
- Same path as external API clients — no special treatment
- `X-Forwarded-Proto: https` prevents `force_ssl` redirect (safe in production because the reverse proxy overwrites this header before forwarding to Rails, so external clients cannot exploit it)

### Internal service requests (claim, step, complete, fail, etc.)

The runner service coordinating with Rails. Goes through `Internal::BaseController`:
- Auth: HMAC-SHA256 signature (`X-Internal-Signature`, `X-Internal-Timestamp`)
- IP restriction: `INTERNAL_ALLOWED_IPS` env var
- Tenant: `Host` header (same mechanism, resolved via `Tenant.scope_thread_to_tenant`)
- No user auth, no collective scoping
- `/internal/*` paths excluded from `force_ssl` redirect
- `/internal/*` paths blocked at the reverse proxy (Caddy returns 403) — only reachable via direct internal network connection

### Internal::BaseController

`app/controllers/internal/base_controller.rb` — base class for internal service APIs. Provides IP restriction, HMAC verification, and tenant resolution. Inherits from `ActionController::Base`, not `ApplicationController`. Future internal services should inherit from this.

## Task lifecycle

1. **Dispatch** (`AgentRunnerDispatchService`): validates agent status + billing, creates ephemeral API token (encrypted with `AGENT_RUNNER_SECRET`), publishes to Redis Stream
2. **Pickup** (`TaskQueue`): reads from stream via consumer group, acquires per-agent lock
3. **Decrypt**: decrypts Bearer token from stream payload
4. **Preflight** (`/internal/.../preflight`): re-checks billing/status (catches stale dispatch checks)
5. **Claim** (`/internal/.../claim`): marks task as running
6. **Execute** (`AgentLoop`): navigate /whoami → LLM loop → tool calls → step reporting
7. **Scratchpad** update: LLM summarizes what to remember, persisted to agent config
8. **Complete** (`/internal/.../complete`): authoritative write of steps, tokens, status

## Token encryption

Plaintext API tokens are encrypted before placing in Redis (protects against Redis access compromise):
- Algorithm: AES-256-GCM
- Key: derived from `AGENT_RUNNER_SECRET` via HKDF (separate from HMAC signing key)
- Format: base64(IV + auth_tag + ciphertext)
- Ruby: `AgentRunnerCrypto.encrypt` / TypeScript: `TokenCrypto.decryptToken`
- These must stay in sync — if you change one, update the other

## Concurrency controls

- **Per-agent lock**: in-memory `Set<agentId>` ensures one task per agent. If busy, message is NACK'd (re-published to stream for later pickup)
- **Global concurrency cap**: `MAX_CONCURRENT_TASKS` (default 100). When at cap, the consumer loop pauses reading. Messages stay pending in Redis.
- **Stream MAXLEN**: `STREAM_MAX_LEN` (default 10,000) with approximate trimming. Prevents unbounded growth. Only completed/ACK'd entries are trimmed.

## Error handling

- **Navigation/action HTTP errors**: caught, recorded as step with error detail, LLM sees the error and decides next action
- **LLM errors**: caught, think step recorded with `llm_error`, error step recorded, task completes with failure
- **Unhandled exceptions** (cancellation, etc.): caught by outer handler, error step recorded, scratchpad update still runs, task completes with failure
- **Step persistence failures**: logged but don't fail the task
- **Scratchpad failures**: logged, `scratchpad_update_failed` step recorded, task still completes
- **Missing consumer group** (e.g., stream/group destroyed out-of-band): `TaskQueue.read` catches `NOGROUP`, recreates the group via `XGROUP CREATE ... MKSTREAM`, and resumes — the runner self-heals without operator action.

## Monitoring

Agent-runner publishes stats to `agent_runner:stats` Redis key every 10 seconds:
- `activeTasks`: currently executing tasks
- `totalTasksProcessed`: lifetime count
- `startedAt`: when the process started
- `lastTaskAt`: when the last task was picked up

Visible at `/system-admin/agent-runner` (requires sys_admin role). Shows runner stats, Redis stream info, and recent task runs.

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AGENT_RUNNER_SECRET` | Yes | — | Shared secret for HMAC signing and token encryption |
| `HARMONIC_HOSTNAME` | Yes | — | Base domain for Host headers. Same value as Rails `HOSTNAME`. Agent-runner prepends the tenant subdomain (e.g., `harmonic.com` → `Host: tenant1.harmonic.com`) |
| `HARMONIC_INTERNAL_URL` | No | `http://web:3000` | Direct TCP URL to Rails container |
| `REDIS_URL` | No | `redis://redis:6379` | Redis connection |
| `LLM_BASE_URL` | No | `http://litellm:4000` or `https://llm.stripe.com` | LLM API endpoint (defaults based on gateway mode) |
| `LLM_GATEWAY_MODE` | No | `litellm` | `litellm` or `stripe_gateway` |
| `STRIPE_GATEWAY_KEY` | No | — | Required in `stripe_gateway` mode |
| `MAX_CONCURRENT_TASKS` | No | `100` | Maximum concurrent task fibers |
| `STREAM_MAX_LEN` | No | `10000` | Redis stream approximate max length |
| `AGENT_TASKS_STREAM` | No | `agent_tasks` | Redis stream name |
| `AGENT_TASKS_CONSUMER_GROUP` | No | `agent_runner` | Consumer group name |
| `AGENT_TASKS_CONSUMER_NAME` | No | `runner-{pid}` | Consumer name (unique per process) |

Rails also needs:
| Variable | Description |
|----------|-------------|
| `AGENT_RUNNER_SECRET` | Same value as agent-runner (for encryption + HMAC verification) |
| `INTERNAL_ALLOWED_IPS` | Comma-separated IPs/CIDRs for internal API access. In Docker, set this to the agent-runner container's bridge-network IP or the container network CIDR; the check uses the TCP peer address (`REMOTE_ADDR`), not the spoofable `X-Forwarded-For` header. |

Local development note: the `agent-runner` compose service sits behind a `profiles: ["llm"]` gate. Start it with `docker compose --profile llm up agent-runner` (or `docker compose --profile llm up -d`) when you want to exercise the full dispatch path locally.

## Rotating `AGENT_RUNNER_SECRET`

The secret has two distinct responsibilities:

1. **HMAC signing** of internal API requests between Rails and agent-runner.
2. **AES-256-GCM key material** (via HKDF) for the ephemeral task tokens published on the Redis stream.

Because the secret is used for encryption, a rotation has a short grace window: any task already dispatched (encrypted token sitting in the stream) is un-decryptable by a runner that has only the new key. Plan accordingly.

Recommended procedure:

1. **Drain in-flight work.** Ensure no new tasks will be dispatched: either pause the humans that trigger them, or temporarily stop creating task runs. Watch the Redis stream length (`XLEN agent_tasks`) drop to zero after the runner has processed the pending entries.
2. **Roll the secret in env for both services simultaneously.** Rails and agent-runner must share the same value; a mismatch produces decrypt failures and HMAC rejections. If deploying rolling (not all-at-once), expect a brief window of 401s and decrypt errors — the runner now surfaces these as typed `TokenDecryptError` failures via `reporter.fail` rather than silently orphaning the task, so affected tasks will be marked failed rather than stuck in `queued`.
3. **Use `rake agent_runner:redispatch_queued`** after the rotation to reissue any tasks that got stuck in `queued` state during the window. The rake guards against dispatching tasks that have already moved to `running` or a terminal state.
4. **Expect nonce cache carryover.** Replay protection stores nonces in Redis with a 5-minute TTL; the rotated secret is unrelated, so the cache stays valid across the rotation.

A future version may prepend a 1-byte key-version prefix to encrypted payloads so the runner can decrypt under both the old and new keys during a rolling window. Until then: drain before rotating.

## Ops: Graceful Shutdown & Orphan Recovery

### Graceful Shutdown

On SIGTERM (sent by `docker compose up -d` during deploys), the runner:

1. Stops reading new tasks from the Redis stream
2. Waits up to 4.5 minutes for in-flight tasks to complete naturally
3. Disconnects Redis and exits cleanly

Docker's `stop_grace_period` is set to 5 minutes in both compose files.
Most tasks complete within 1-3 minutes. If the timeout expires, remaining
tasks become orphans (see below).

### Orphan Recovery

Two mechanisms detect and clean up orphaned tasks:

**XAUTOCLAIM (in the runner):** Every 30 seconds, the runner reclaims
Redis stream entries that have been pending for >2 minutes without ACK.
For each reclaimed entry:
- If the task already reached a terminal state on Rails → ACK and skip
- If the task is still "running" → mark it failed with
  `orphaned_after_process_crash` and ACK
- If claimed 3+ times without completion → dead-letter it as
  `dead_lettered_after_N_claims` (prevents infinite retry loops)

The runner maintains a Set of active task IDs to avoid reclaiming entries
for tasks it is currently executing (XAUTOCLAIM's idle timer grows
continuously from the initial read, not from last activity).

**OrphanedTaskSweepJob (Sidekiq, every 10 min):** Catches cases
XAUTOCLAIM can't handle (Redis wiped, stream deleted, runner never
restarted). Finds `AiAgentTaskRun` rows with `status: "running"` and
`started_at > 15 minutes ago`, marks them failed with `orphaned_timeout`.

### Checking for Orphans

```ruby
# In Rails console:
AiAgentTaskRun.unscoped_for_system_job
  .where(status: "running")
  .where("started_at < ?", 15.minutes.ago)
```

The admin page at `/system-admin/agent-runner` shows task runs with their
status — filter by "failed" to see orphaned tasks (look for error
messages containing "orphaned" or "dead_lettered").

### Manual Recovery

The `rake agent_runner:redispatch_queued` task still exists as a fallback
for tasks stuck in "queued" state (dispatched to Redis but never picked
up). This is rarely needed — the XAUTOCLAIM loop handles most cases
automatically.
