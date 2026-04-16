# Agent Runner: Node.js Service to Replace Sidekiq Agent Execution

## Status

**All phases complete.** The agent-runner service handles all AI agent task execution in production; the old Sidekiq-based stack has been deleted; the standalone `harmonic-agent/` PoC has been removed; the `mcp-server` has been audited and brought current.

For the current documentation of how the system works, see [docs/AGENT_RUNNER.md](../../docs/AGENT_RUNNER.md). The pseudocode and descriptions below were written during planning and may not match the final implementation in every detail — the code and docs are the source of truth.

**What's done:**
- Phase 1: agent-runner TypeScript service, Rails internal API, dispatch service, crypto, migration, admin monitoring, Docker Compose service, CI.
- Phase 2: all four dispatch call sites switched to `AgentRunnerDispatchService`; resource tracking migrated to Bearer-token linkage; old `AgentNavigator`, `AgentQueueProcessorJob`, `LLMClient`, `LLMPricing`, `StripeModelMapper`, `IdentityPromptLeakageDetector` deleted (~1,500 LOC + tests); production compose service + required env vars + published image; rake task for orphan task re-dispatch; NOGROUP self-heal in runner.
- Phase 3: `harmonic-agent/` directory deleted (standalone PoC harness, superseded by mcp-server for external agent use cases).
- Phase 4: `mcp-server/` audited — source uses current `/collectives/` convention; `dist/` is gitignored so stale local builds self-resolve on next `npm run build`; CONTEXT.md already current; README parameter-name bug fixed (`url` → `path`).

**Follow-up (separate work):**
- Migrate thread-local ambient state to `ActiveSupport::CurrentAttributes` — see [current-attributes-migration.md](current-attributes-migration.md).

## Goal

Replace the Sidekiq-based internal agent execution (`AgentQueueProcessorJob` + `AgentNavigator` + `LLMClient`) with a dedicated Node.js service (`agent-runner`). This solves the concurrency bottleneck (5 Sidekiq threads blocking on LLM I/O) by leveraging Node's async model, which can handle hundreds of concurrent agent tasks in a single process.

## Why

- **Concurrency:** Each agent task makes 10-30+ LLM calls, each blocking for 5-60 seconds. Ruby/Sidekiq dedicates a thread per task for the entire duration. Node.js `await`s are non-blocking — a single thread handles hundreds of concurrent tasks with ~200-500 MB total memory vs. ~2-3 GB for 100 Ruby threads.
- **Simpler scaling:** One Node process replaces a dedicated high-concurrency Sidekiq process. No need to manage thread counts, DB connection pools, or memory limits per thread.
- **Code already exists:** `harmonic-agent` contains a working TypeScript/Effect.js agent loop (navigate, execute_action, LLM tool-use protocol) that talks to Rails over HTTP. The core logic and patterns are proven.
- **Cleaner separation:** Rails handles the platform (auth, data, UI, task queue). Node handles agent execution (LLM calls, reasoning, tool use). Each does what it's good at.

## Architecture

```
Rails app                              agent-runner (Node.js)
  │                                        │
  │  AiAgentTaskRun created                │
  │  (status: queued)                      │
  │                                        │
  │  ── Redis stream (XADD) ────────────►  │  picks up task (XREADGROUP)
  │                                        │
  │  ◄── GET /whoami ──────────────────    │  fetch identity + scratchpad
  │  ◄── GET /collectives/team ────────    │  await navigate()
  │  ── markdown response ──────────►      │  await llmCall()
  │  ◄── POST /actions/create_note ────    │  await executeAction()
  │  ── result ─────────────────────►      │  ...loop...
  │                                        │
  │  ◄── POST /internal/tasks/:id/done     │  report results
  │                                        │
  │  AiAgentTaskRun updated                │
  │  (status: completed)                   │
```

### What lives where

| Concern | Where | Why |
|---------|-------|-----|
| Task queue (create, status, history) | Rails | It's data — belongs with the DB |
| Task UI (run, view results, cancel) | Rails | User-facing, server-rendered |
| Agent execution (LLM loop, reasoning) | agent-runner | I/O-bound, benefits from async |
| System prompts, tool definitions | agent-runner | Part of the agent logic |
| Scratchpad persistence | Rails (via API) | It's data |
| Step persistence | Rails (via internal API) | It's data, viewable in UI |
| Billing checks | Rails (before dispatching) AND agent-runner (before execution) | Double-gate for staleness protection |
| Stuck task detection | Rails (periodic job) | Checks for tasks with no progress |
| Capability enforcement | Rails (on every API request) | Existing middleware, unchanged |
| Rate limiting | Rails (automation dispatcher) | Existing logic, unchanged |

---

## Phase 1: Build agent-runner

### Core agent loop

Port the logic from `AgentNavigator` and `harmonic-agent` into a new `agent-runner` service:

- **Task pickup:** Redis Streams (`XREADGROUP` with consumer group) — persistent, survives restarts, supports acknowledgment
- **Auth:** Ephemeral internal API tokens (Rails creates one per task, encrypts the plaintext with `AGENT_RUNNER_SECRET`, and includes it in the stream payload; agent-runner decrypts locally)
- **Navigate:** `GET {path}` with `Accept: text/markdown` and Bearer token — same as existing markdown API
- **Execute action:** `POST {path}/actions/{name}` with JSON params — same as existing action API
- **LLM calls:** OpenAI-compatible chat completions API. Stripe AI Gateway in production, LiteLLM in dev. Model is per-agent (from `agent_configuration["model"]`). Uses the standard tool calling convention (works across all providers via the gateway) rather than JSON-in-text parsing
- **Step persistence:** Call an internal Rails endpoint after each step to update `steps_data` in real-time
- **Completion:** Call an internal Rails endpoint with final status, message, and accumulated token counts.

### Collective context

The current `AgentQueueProcessorJob` resolves the agent's collective via `resolve_collective(task_run)` and passes it to `AgentNavigator`. Agent-runner doesn't need this in the dispatch payload — the agent discovers its collective context by navigating to `/whoami`, which includes collective membership. The `/whoami` page is tenant-scoped via the Bearer token, so the correct collective context is already available.

### System prompt

Port from `AgentNavigator.system_prompt` (app/services/agent_navigator.rb):
- Boundary hierarchy (ethical foundations → platform rules → agent identity → user content)
- Harmonic concepts (OODA loop, collectives, notes, decisions, commitments, cycles)
- Available actions and URL patterns
- Scratchpad context

Improvements over current implementation:
- Use native tool_use protocol instead of asking LLM to output JSON
- Cleaner separation of identity prompt from system instructions

### Concurrency model

```typescript
// Pure core: builds messages from task state (no I/O)
const buildInitialMessages = (task: TaskPayload, identity: string): Message[] =>
  [systemMessage(buildSystemPrompt(task, identity)),
   userMessage(task.task)];

const buildToolResultMessages = (toolCalls: ToolCall[], results: ToolResult[]): Message[] =>
  toolCalls.map((tc, i) => toolMessage(tc.id, results[i]));

// Effect service: the agent loop (I/O at the boundary)
const runTask = (task: TaskPayload) =>
  Effect.gen(function* () {
    const llm = yield* LLMClient;
    const harmonic = yield* HarmonicClient;
    const reporter = yield* TaskReporter;

    // Decrypt Bearer token from stream payload (encrypted with AGENT_RUNNER_SECRET)
    const token = decrypt(task.encryptedToken);

    // Pre-flight: re-check billing/status (catches stale dispatch checks)
    yield* reporter.preflight(task.taskRunId);

    yield* reporter.claim(task.taskRunId);

    const identity = yield* harmonic.navigate("/whoami", token);
    const leakageDetector = extractCanary(identity.content); // pure
    let messages = buildInitialMessages(task, identity.content);
    let totalInputTokens = 0;
    let totalOutputTokens = 0;

    for (let step = 0; step < task.maxSteps; step++) {
      // Check for cancellation before each LLM call
      yield* checkCancellation(task.taskRunId);

      const response = yield* llm.chat(messages, task.model);

      // Accumulate token usage across all LLM calls
      totalInputTokens += response.usage.inputTokens;
      totalOutputTokens += response.usage.outputTokens;

      // Check for identity prompt leakage (pure function)
      const leakage = checkLeakage(leakageDetector, response.content);
      if (leakage.leaked) {
        yield* reporter.step(task.taskRunId, [{
          type: "security_warning", detail: leakage.reasons.join(", "),
        }]);
      }

      if (response.finishReason === "stop") break;

      const results = yield* Effect.forEach(
        response.toolCalls,
        (tc) => executeToolCall(harmonic, tc),
        { concurrency: 1 }
      );

      yield* reporter.step(task.taskRunId, response.toolCalls, results);
      messages = [...messages, assistantMessage(response),
                  ...buildToolResultMessages(response.toolCalls, results)];
    }

    // Scratchpad update: prompt LLM to summarize what to remember
    yield* updateScratchpad(task, messages, llm, reporter);

    yield* reporter.complete(task.taskRunId, {
      ...buildResult(messages),
      inputTokens: totalInputTokens,
      outputTokens: totalOutputTokens,
      totalTokens: totalInputTokens + totalOutputTokens,
    });
  }).pipe(
    Effect.catchAll((error) =>
      TaskReporter.pipe(
        Effect.flatMap((r) => r.fail(task.taskRunId, error.message))
      )
    )
  );

// Many tasks run concurrently — Effect fibers yield on every I/O operation
// One-task-per-agent enforced by activeAgents set
const processQueue = Effect.gen(function* () {
  const queue = yield* TaskQueue;
  const agentLock = yield* AgentLock;

  yield* pipe(
    queue.subscribe,
    Effect.flatMap((entry) =>
      agentLock.tryAcquire(entry.task.agentId).pipe(
        Effect.flatMap((acquired) =>
          acquired
            ? Effect.fork(
                runTask(entry.task).pipe(
                  Effect.ensuring(agentLock.release(entry.task.agentId)),
                  Effect.ensuring(queue.ack(entry.id))  // acknowledge on completion
                )
              )
            : queue.nack(entry.id)  // agent busy — re-queue for later delivery
        )
      )
    ),
    Effect.forever
  );
});
```

Hundreds of `runTask` fibers execute concurrently. Every `yield*` on an I/O operation (LLM call, HTTP request) suspends the fiber, freeing the event loop for other fibers. Effect's fiber scheduler handles this automatically.

### Task dispatch from Rails

When `AiAgentTaskRun` is created:

1. Rails performs billing checks, agent status validation (keep existing logic from `AgentQueueProcessorJob.run_task`)
2. Creates an ephemeral internal API token for the task, linked to the task run (`ai_agent_task_run_id` on the token)
3. Publishes task payload to Redis Stream (token ID only — not plaintext)
4. agent-runner picks it up, fetches token via secure internal endpoint, and starts execution

```ruby
# In Rails — replaces AgentQueueProcessorJob.perform
def dispatch_to_agent_runner(task_run)
  ai_agent = task_run.ai_agent
  tenant = task_run.tenant

  # Precondition checks (match AgentQueueProcessorJob lines 17-22)
  return unless ai_agent&.ai_agent?
  return unless tenant&.ai_agents_enabled?

  # Agent status checks (match AgentQueueProcessorJob lines 101-119)
  agent_tenant_user = ai_agent.tenant_users.find_by(tenant_id: tenant.id)
  if ai_agent.suspended? || agent_tenant_user&.archived? || ai_agent.pending_billing_setup?
    status_msg = if ai_agent.pending_billing_setup?
      "pending billing setup"
    elsif ai_agent.suspended?
      "suspended"
    else
      "deactivated"
    end
    task_run.update!(status: "failed", success: false, error: "Agent is #{status_msg}.")
    task_run.notify_parent_automation_runs!
    return
  end

  # Billing checks (match AgentQueueProcessorJob lines 122-153)
  billing_customer = ai_agent.billing_customer
  if tenant.feature_enabled?("stripe_billing")
    unless billing_customer&.active?
      task_run.update!(status: "failed", success: false,
        error: "Billing is not set up. Please set up billing at /billing before running AI agents.")
      task_run.notify_parent_automation_runs!
      return
    end
    # Stamp immutable billing attribution
    task_run.update!(stripe_customer_id: billing_customer.id)

    # Pre-flight credit balance check (match AgentQueueProcessorJob lines 141-153)
    if ENV.fetch("LLM_GATEWAY_MODE", "litellm") == "stripe_gateway"
      credit_balance = StripeService.get_credit_balance(billing_customer)
      if credit_balance == 0
        task_run.update!(status: "failed", success: false,
          error: "Insufficient credit balance. Add funds at /billing before running agents.")
        task_run.notify_parent_automation_runs!
        return
      end
    end
  end

  # Create ephemeral token linked to task run
  token = ApiToken.create_internal_token(
    user: ai_agent,
    tenant: tenant,
    ai_agent_task_run: task_run,  # new: links token to task run
  )

  # Encrypt plaintext token with AGENT_RUNNER_SECRET (AES-256-GCM, HKDF-derived key)
  encrypted_token = AgentRunnerCrypto.encrypt(token.plaintext_token)

  # Publish to Redis Stream — encrypted token is safe in Redis
  payload = {
    task_run_id: task_run.id,
    encrypted_token: encrypted_token,
    task: task_run.task,
    max_steps: task_run.max_steps,
    model: task_run.model,
    agent_id: ai_agent.id,
    tenant_subdomain: tenant.subdomain,
    stripe_customer_stripe_id: billing_customer&.stripe_id,
  }
  Redis.current.xadd("agent_tasks", payload)
end
```

### Two types of HTTP request

Agent-runner makes two fundamentally different types of request to Rails. The auth model and controller path differ:

**1. Agent API requests** (navigate, execute_action) — the agent acting as a user:
- Go through `ApplicationController`, same as any external API client
- Auth: `Authorization: Bearer {token}` — the agent's ephemeral API token
- Subject to normal tenant scoping, capability checks, API authorization
- No special treatment vs. an external client using the markdown API

**2. Internal service requests** (claim, step, complete, fail, etc.) — the runner service coordinating with Rails:
- Go through `Internal::BaseController` (inherits from `ActionController::Base`, not `ApplicationController`)
- Auth: HMAC-SHA256 signature + IP restriction (no user auth — the caller is a trusted service)
- Tenant scoping from subdomain (same mechanism, different auth)
- No collective scoping — internal services operate at the tenant level

### HTTP routing

All requests from agent-runner go directly to the Rails container over the Docker network (`HARMONIC_INTERNAL_URL`, e.g., `http://web:3000`). The `Host` header is set to `{subdomain}.{hostname}` so Rails resolves the correct tenant from `request.subdomain`.

For agent API requests, `X-Forwarded-Proto: https` is set so `config.force_ssl` doesn't redirect. Rails trusts this header from private network IPs (Docker backend) via `config.action_dispatch.trusted_proxies`.

For internal API requests, `/internal/*` paths are excluded from the SSL redirect in `config.ssl_options`.

Config:
- `HARMONIC_INTERNAL_URL` — TCP destination (e.g., `http://web:3000`)
- `HARMONIC_HOSTNAME` — base domain for Host header (e.g., `app.harmonic.local`)

### Internal::BaseController

Base class for internal service-to-service APIs (`app/controllers/internal/base_controller.rb`). Establishes a reusable pattern for future internal services:

- Inherits from `ActionController::Base` (not `ApplicationController`)
- `before_action :verify_ip_restriction` — checks `request.remote_ip` against `INTERNAL_ALLOWED_IPS`
- `before_action :verify_hmac_signature` — HMAC-SHA256 with 5-minute replay protection
- `before_action :resolve_tenant_from_subdomain` — calls `Tenant.scope_thread_to_tenant` from `request.subdomain`
- No user auth, no collective scoping, no CSRF

### Internal API endpoints

```
POST /internal/agent-runner/tasks/:id/claim         — Mark task as running, set started_at
POST /internal/agent-runner/tasks/:id/step          — Append step to steps_data
POST /internal/agent-runner/tasks/:id/complete       — Mark done { success, final_message, input_tokens, output_tokens, total_tokens }
POST /internal/agent-runner/tasks/:id/fail           — Mark failed { error }
PUT  /internal/agent-runner/tasks/:id/scratchpad     — Update agent scratchpad
GET  /internal/agent-runner/tasks/:id/status         — Check task status (for cancellation)
POST /internal/agent-runner/tasks/:id/preflight      — Re-check billing/status before execution
```

HMAC signature format (same as `WebhookDeliveryService`):
- `X-Internal-Signature: sha256={HMAC-SHA256(secret, "#{timestamp}.#{body}")}`
- `X-Internal-Timestamp: {unix_timestamp}`
- Requests older than 5 minutes are rejected (replay protection)
- GET requests sign an empty string for the body

### Security: Token handling

**Problem:** Plaintext API tokens must not be stored in Redis (anyone with Redis access can read them).

**Solution:**
Encrypt the plaintext using the shared secret (`AGENT_RUNNER_SECRET`) before placing it in the Redis stream payload. Agent-runner decrypts locally.

1. Rails creates the ephemeral token, encrypts the plaintext with AES-256-GCM (key derived from `AGENT_RUNNER_SECRET` via HKDF, so the encryption key is distinct from the HMAC signing key), and includes the encrypted token directly in the Redis stream payload
2. Agent-runner reads the stream, decrypts with `AGENT_RUNNER_SECRET`, and holds the plaintext in memory for the duration of the task
3. No separate fetch endpoint needed — the encrypted token is safe in Redis because it can't be decrypted without the shared secret
4. The ephemeral token is destroyed by Rails when the task completes (via the `/complete` or `/fail` callback), or by `CleanupExpiredInternalTokensJob` if the task crashes

### Security: Billing double-gate

**Problem:** Billing is checked at dispatch time, but the task may sit in the queue. By the time agent-runner picks it up, the billing status could have changed (credits exhausted, subscription cancelled).

**Solution:** Agent-runner calls `POST /internal/agent-runner/tasks/:id/preflight` before starting execution. This endpoint re-checks:
- Agent not suspended/archived
- Billing customer still active
- Credit balance > 0 (in stripe_gateway mode)

If the preflight fails, agent-runner calls `/fail` with the reason. This matches the current behavior where `AgentQueueProcessorJob.run_task` checks billing at execution time, not just at queue time.

### One-task-per-agent concurrency control

**Problem:** The current system uses `ai_agent.with_lock` (Postgres row lock) to ensure only one task runs per agent. Agent-runner doesn't have DB access.

**Solution:** Agent-runner maintains an in-memory `Set<agentId>` of agents with active fibers. When a task arrives:
1. If the agent is already running a task, re-queue the message (NACK in Redis Streams consumer group) for later delivery
2. If not, add the agent to the set, run the task, remove from set when done

This is simpler than a distributed lock and sufficient because agent-runner is a single process. If you later need multiple agent-runner instances, switch to a Redis-based lock.

### Task cancellation

**Problem:** Users can cancel running tasks via UI, but the current Sidekiq job doesn't check mid-run either.

**Solution:** Agent-runner checks task status before each LLM call (the most expensive/slow operation):
- Call `GET /internal/agent-runner/tasks/:id/status`
- If status is `cancelled`, stop the loop and report failure
- This adds ~1ms of latency per step (negligible vs. 10s LLM calls)

### Scratchpad update

Port from `AgentNavigator` (lines 290-349):
- After the main loop completes, prompt the LLM to summarize what to remember
- Parse JSON response for scratchpad content
- Sanitize (remove control characters) and truncate to 10,000 chars
- Call `PUT /internal/agent-runner/tasks/:id/scratchpad` to persist
- Failures are logged but don't fail the task

### Identity prompt leakage detection

Port from `IdentityPromptLeakageDetector`:
- Extract canary token from `/whoami` response at start of task
- Check every LLM response for canary token presence or substantial overlap with identity prompt
- Log security warnings as step entries (type: `security_warning`)
- This lives in agent-runner's `core/` as pure functions (canary extraction, overlap detection)

### Resource tracking

**Problem:** Currently uses thread-local `AiAgentTaskRun.current_id` in `ApiHelper.track_task_run_resource()` to associate created resources with the task run. Agent-runner makes HTTP requests from a separate process — no thread-local.

**Solution:** Add `ai_agent_task_run_id` to the `api_tokens` table. When Rails creates the ephemeral token for a task, it stamps the task run ID on the token. When agent-runner makes API requests with that token, Rails reads the task run ID from the token and uses it in `track_task_run_resource()` — replacing the thread-local lookup with a token-based lookup. The existing `AiAgentTaskRunResource` tracking continues to work unchanged.

### Capability enforcement

No changes needed. `CapabilityCheck.allowed?` runs as middleware on every Rails API request. When agent-runner calls `POST /actions/create_note`, Rails checks the agent's capabilities the same way it does today. Blocked actions return HTTP 403.

### Rate limiting and chain protection

No changes needed. Rate limiting (3 agent rule executions/min, 100 tenant runs/min) and chain protection (depth < 3, no loops, max 10 rules/chain) are enforced at the automation dispatch layer in Rails, before a task is ever created. Agent-runner only sees tasks that have already passed these gates.

### Stuck task detection

Adapt the existing approach:
- Periodic Rails job checks for tasks in `running` status with no step update in the last N minutes
- agent-runner reports steps in real-time, so "no recent step" = stuck
- The step reporting endpoint updates `updated_at` on the task run, providing a natural heartbeat
- No separate heartbeat endpoint needed

### Project structure

Follows the **functional core, imperative shell** pattern: pure functions for agent logic (prompt construction, response parsing, action selection), effectful services at the boundary (HTTP, Redis, LLM).

```
agent-runner/
  src/
    index.ts              ← entry point, layer composition, program execution
    core/                 ← FUNCTIONAL CORE (pure, no I/O)
      AgentContext.ts      ← system prompt construction, tool definitions
      ActionParser.ts      ← parse LLM responses into typed actions
      PromptBuilder.ts     ← build messages from task + page content + history
      StepBuilder.ts       ← construct step records from actions/results
      LeakageDetector.ts   ← canary extraction, overlap detection (pure)
      ScratchpadParser.ts  ← parse and sanitize scratchpad updates (pure)
    services/             ← IMPERATIVE SHELL (effectful, I/O boundaries)
      AgentLoop.ts         ← Effect-based loop: LLM call → tool execution → repeat
      HarmonicClient.ts    ← Effect service: HTTP client for Rails markdown API
      TaskReporter.ts      ← Effect service: reports steps/completion/failure to Rails
      LLMClient.ts         ← Effect service: OpenAI-compatible chat completions
      TaskQueue.ts         ← Effect service: Redis Streams consumer
      AgentLock.ts         ← Effect service: per-agent concurrency control
    config/
      Config.ts           ← Effect Layer for environment configuration
    errors/
      Errors.ts           ← Typed error classes (Data.TaggedEnum)
  Dockerfile
  package.json
  tsconfig.json
  vitest.config.ts
```

### Tech stack

- **Runtime:** Node.js 22
- **Language:** TypeScript with maximum strictness. `tsconfig.json` enables all strict checks:
  ```json
  {
    "compilerOptions": {
      "strict": true,
      "noUncheckedIndexedAccess": true,
      "noUnusedLocals": true,
      "noUnusedParameters": true,
      "noFallthroughCasesInSwitch": true,
      "forceConsistentCasingInFileNames": true,
      "exactOptionalPropertyTypes": true,
      "noPropertyAccessFromIndexSignature": true,
      "noImplicitReturns": true,
      "noImplicitOverride": true,
      "verbatimModuleSyntax": true
    }
  }
  ```
  `strict: true` enables `strictNullChecks`, `strictFunctionTypes`, `strictBindCallApply`, `strictPropertyInitialization`, `noImplicitAny`, `noImplicitThis`, `alwaysStrict`, and `useUnknownInCatchVariables`. The additional flags close remaining gaps: `noUncheckedIndexedAccess` forces handling of `undefined` from array/object indexing, `exactOptionalPropertyTypes` distinguishes `undefined` from missing, and `noPropertyAccessFromIndexSignature` prevents untyped property access on index signatures. Combined with Effect.js typed errors, this gives us compile-time safety comparable to Sorbet strict mode in the Rails codebase.
- **Architecture:** Effect.js — functional core / imperative shell. Services as Effect Layers, errors as typed values, dependencies via Effect Context.
- **LLM client:** OpenAI-compatible HTTP (chat completions endpoint). No provider-specific SDK — the Stripe AI Gateway and LiteLLM both expose the OpenAI-compatible API. Users choose the model; agent-runner is model-agnostic.
- **HTTP client:** Built-in fetch (wrapped in Effect for error handling and cancellation)
- **Redis client:** `ioredis` for Streams consumer group (wrapped in Effect Layer)
- **Testing:** Vitest. Pure core functions tested without mocks. Effect services tested with test layers.

### Model agnosticism

Agent-runner does NOT depend on any provider-specific SDK. It speaks the OpenAI-compatible chat completions API:

```
POST {llm_base_url}/chat/completions
{
  "model": "anthropic/claude-sonnet-4-20250514",  // or any Stripe-supported model
  "messages": [...],
  "tools": [...]
}
```

The model is specified per-agent in `agent_configuration["model"]` and passed through to the LLM endpoint. The Stripe AI Gateway handles model routing. In development, LiteLLM provides the same interface.

Tool use follows the OpenAI tool calling convention (works across Claude, GPT, Gemini, etc. via the gateway):
- Request includes `tools` array with function definitions
- Response includes `tool_calls` in assistant message
- Client sends `tool` role messages with results

---

## Testing Strategy

Red-green TDD across both codebases. Most tests run against a single service — only a small number of e2e smoke tests require both running.

### Step 1: Write Rails tests for new behavior (RED → GREEN)

Before building agent-runner, write tests for the new Rails-side code. These run with Rails only (no agent-runner needed).

**Internal API controller tests** (`test/controllers/internal/agent_runner_controller_test.rb`):
- HMAC signature verification: valid signature passes, invalid rejected, expired timestamp rejected
- IP restriction: allowed IP passes, disallowed IP gets 403
- `/claim`: transitions queued → running, sets started_at, rejects already-running tasks
- `/step`: appends to steps_data, increments steps_count, updates updated_at
- `/complete`: sets status/success/final_message/tokens/cost, destroys ephemeral token, calls notify_parent_automation_runs!
- `/fail`: sets status/error, destroys ephemeral token, calls notify_parent_automation_runs!
- `/scratchpad`: updates agent_configuration scratchpad, sanitizes content, truncates to 10KB
- `/status`: returns current task status (for cancellation detection)
- `/preflight`: re-checks agent status, billing active, credit balance; returns pass/fail with reason
- Token encryption: `AgentRunnerCrypto.encrypt` / agent-runner `decrypt` produce correct round-trip

**Dispatch tests** (`test/services/dispatch_to_agent_runner_test.rb`):
Port behavioral assertions from existing `test/jobs/agent_queue_processor_job_test.rb`:
- Suspended agent → task fails immediately (never published to stream)
- Archived agent → task fails immediately
- Pending billing setup → task fails immediately
- Billing not active (when stripe_billing enabled) → task fails
- Credit balance zero → task fails
- Successful dispatch → publishes correct payload to Redis Stream with encrypted token
- Stripe customer ID stamped on task run before publish
- Ephemeral token created with correct user/tenant/task_run linkage
- Encrypted token in payload can be decrypted by agent-runner

**Resource tracking tests** (`test/services/api_helper_resource_tracking_test.rb`):
Port from existing tests that use thread-local `AiAgentTaskRun.current_id`:
- Request with task-linked token → created resources associated with task run
- Request with regular token (no task run) → no resource tracking
- Existing resource tracking assertions still pass with token-based lookup

**Stuck task detection tests**:
- Task with no step update for N minutes → marked failed
- Task with recent step update → not marked failed

### Step 2: Write agent-runner tests (RED → GREEN)

These run with Vitest only (no Rails needed).

**Pure core tests** (no mocks, no I/O):
- `AgentContext.test.ts`: system prompt includes identity prompt, scratchpad, boundary hierarchy, tool definitions
- `ActionParser.test.ts`: parses tool_calls from OpenAI-format responses, handles malformed responses
- `PromptBuilder.test.ts`: builds correct message sequences from task + page content + history
- `StepBuilder.test.ts`: constructs step records with correct types and timestamps
- `LeakageDetector.test.ts`: port assertions from `test/services/identity_prompt_leakage_detector_test.rb` — canary extraction, exact match detection, substring overlap, threshold calculations
- `ScratchpadParser.test.ts`: JSON parsing, control character removal, 10KB truncation, malformed input handling

**Effect service tests** (mock layers, no real I/O):
- `AgentLoop.test.ts`:
  - Navigates to /whoami first, then starts LLM loop
  - Stops on finish_reason "stop"
  - Stops at max_steps
  - Reports step after each tool execution
  - Calls complete on success
  - Calls fail on error
  - Checks cancellation before each LLM call — stops if cancelled
  - Runs scratchpad update after main loop
  - Leakage detection runs on every LLM response
- `TaskQueue.test.ts`: picks up tasks from stream, acknowledges on completion, NACKs when agent is locked
- `AgentLock.test.ts`: allows one task per agent, blocks concurrent, releases on completion and on failure
- `TaskReporter.test.ts`: HMAC-signs requests correctly, calls correct endpoints, handles error responses
- `HarmonicClient.test.ts`: sends correct headers (Accept: text/markdown, Bearer token), handles HTTP errors

### Step 3: End-to-end smoke tests (both services)

A small number of tests that verify the full flow. Run in CI with Rails + agent-runner + LiteLLM (or mock LLM endpoint).

- Task created → agent-runner picks up → navigates → executes actions → completes → task run has correct status, steps, resources
- Task created for agent with blocked capability → action rejected → task still completes (with error step)
- Task cancelled mid-execution → agent-runner stops → task marked failed
- Agent-runner crashes/restarts → unacknowledged tasks redelivered → completed successfully

These tests need a deterministic mock LLM that returns predictable tool calls. A simple HTTP server that returns canned responses, run as a test fixture.

### Test porting reference

Map of existing test files to their agent-runner equivalents:

| Existing Ruby test | What it asserts | New test location |
|---|---|---|
| `test/jobs/agent_queue_processor_job_test.rb` | Billing gates, agent status checks, stuck recovery, task completion | `test/services/dispatch_to_agent_runner_test.rb` (Rails) + `AgentLoop.test.ts` (agent-runner) |
| `test/services/agent_navigator_test.rb` | Navigation, action execution, step recording, scratchpad update, error handling | `AgentLoop.test.ts` + `PromptBuilder.test.ts` + `ActionParser.test.ts` (agent-runner) |
| `test/services/identity_prompt_leakage_detector_test.rb` | Canary extraction, leakage detection thresholds | `LeakageDetector.test.ts` (agent-runner, pure) |
| `test/services/llm_client_test.rb` | HTTP request format, error handling, response parsing | `LLMClient.test.ts` (agent-runner) |
| `test/services/markdown_ui_service_test.rb` | Navigate/execute_action HTTP calls, token lifecycle | `HarmonicClient.test.ts` (agent-runner) + internal API controller tests (Rails) |
| `test/services/api_helper_resource_tracking_test.rb` | Resource association with task runs | Updated in-place (Rails, token-based instead of thread-local) |

### When to delete old tests

Old Ruby test files are deleted in Phase 2, only after:
1. All corresponding new Rails tests pass
2. All corresponding agent-runner tests pass
3. E2e smoke tests pass
4. Feature flag rollout has been validated in staging

---

## Phase 2: Remove Ruby agent execution code

Once agent-runner is operational, remove the code it replaces.

### Delete entirely

| File | Reason |
|------|--------|
| `app/services/agent_navigator.rb` | Agent loop — now in agent-runner |
| `app/services/markdown_ui_service.rb` | Internal HTTP dispatch — agent-runner uses real HTTP |
| `app/services/identity_prompt_leakage_detector.rb` | Ported to agent-runner |
| `app/services/llm_client.rb` | LLM API client — now in agent-runner |
| `app/services/llm_pricing.rb` | Cost estimation — removed, actual costs to come from Stripe |
| `app/services/stripe_model_mapper.rb` | Model mapping — now in agent-runner |
| `app/jobs/agent_queue_processor_job.rb` | Sidekiq job — replaced by agent-runner |
| `test/` files for all of the above | Tests for deleted code |

### Modify

| File | Change |
|------|--------|
| `app/controllers/ai_agents_controller.rb` | `execute_task` calls `AgentRunnerDispatchService.dispatch` instead of enqueuing `AgentQueueProcessorJob` |
| `app/services/automation_executor.rb` | `execute_agent_rule` calls `AgentRunnerDispatchService.dispatch` instead of enqueuing `AgentQueueProcessorJob` |
| `app/services/api_helper.rb` | `track_task_run_resource` reads task run ID from token instead of thread-local |
| `docker-compose.production.yml` | Add agent-runner service with appropriate resource limits |

Already done in Phase 1:
| `app/models/api_token.rb` | `belongs_to :ai_agent_task_run`, updated `create_internal_token` |
| `app/models/ai_agent_task_run.rb` | `has_many :api_tokens, dependent: :destroy` |
| `docker-compose.yml` | agent-runner service added |
| `config/routes.rb` | Internal API routes |
| `config/environments/production.rb` | SSL redirect exclusion for `/internal/*` |

### Keep unchanged

- `AiAgentTaskRun` model — task tracking, steps, token usage all stay. agent-runner writes to it via internal API.
- `AiAgentTaskRunResource` — resource tracking, now linked via token instead of thread-local
- User model, agent configuration, capabilities — all unchanged
- `CapabilityCheck` — runs on Rails API requests, unchanged
- `AutomationDispatcher` rate limiting and `AutomationContext` chain protection — unchanged
- `CleanupExpiredInternalTokensJob` — still cleans up orphaned internal tokens
- `StripeService` credit balance checks — called by preflight endpoint
- LiteLLM config and docker services — still needed for development

---

## Phase 3: Delete harmonic-agent ✅

`harmonic-agent` was a proof of concept for external webhook-driven agents. With MCP-compatible frameworks (OpenClaw, Hermes, etc.) growing, maintaining a standalone agent harness isn't needed. The `mcp-server` provides the reference implementation for external tool access.

- [x] Delete `harmonic-agent/` directory
- [x] Confirm no CI references (none found in `.github/workflows/`)
- [x] Confirm no active doc references (only historical CHANGELOG entries remain, which is correct)

---

## Phase 4: Clean up mcp-server ✅

With harmonic-agent gone, the MCP server is the sole external agent interface. Audited:

- [x] `src/` uses `/collectives/` convention (current)
- [x] `dist/` is gitignored — stale local builds self-resolve on next `npm run build`
- [x] CONTEXT.md is current (uses `/collectives/` throughout)
- [x] Fixed README inconsistency: documented `url` parameter didn't match code's `path` parameter
- [x] Tests pass (16/16)
- Consider adding task lifecycle tools later if MCP client users want to interact with the task system (not needed now)

---

## Migration

### Database changes
- Add `ai_agent_task_run_id` (uuid, FK, nullable) to `api_tokens` — links ephemeral tokens to task runs for resource tracking
- No changes to `ai_agent_task_runs` schema

### New internal controllers
- `Internal::BaseController` — base class for internal service APIs: IP restriction, HMAC verification, tenant resolution from subdomain. Inherits from `ActionController::Base`, not `ApplicationController`.
- `Internal::AgentRunnerController` — handles claim, step, complete, fail, scratchpad, status, preflight
- Authenticated via IP restriction (`INTERNAL_ALLOWED_IPS`) + HMAC-SHA256 signature verification (`AGENT_RUNNER_SECRET`)
- Tenant scoped via subdomain in `Host` header (same mechanism as external requests)
- `/internal/*` paths excluded from `force_ssl` redirect in production

### Infrastructure
- Add agent-runner container to deployment
- Configure Redis Streams consumer group
- Set `AGENT_RUNNER_SECRET` in both Rails and agent-runner environments (used for HMAC signing/verification and token encryption)
- Set `INTERNAL_ALLOWED_IPS` in Rails environment (agent-runner's IP or Docker network CIDR)
- Set `HARMONIC_HOSTNAME` in agent-runner environment (base domain for Host headers, e.g., `app.harmonic.local`)
- Set `HARMONIC_INTERNAL_URL` in agent-runner environment (direct TCP to Rails, e.g., `http://web:3000`)
- Set LLM provider credentials in agent-runner environment (`LLM_BASE_URL`, `STRIPE_GATEWAY_KEY` or `LITELLM_URL`)
- Resource requirements: ~200-500 MB memory for hundreds of concurrent tasks

### Production deployment checklist

**Pre-deploy (do once, or whenever rotating the secret):**
- [ ] Generate `AGENT_RUNNER_SECRET`: `openssl rand -hex 32` (64-char hex). Store in the production secret manager.
- [ ] Add `AGENT_RUNNER_SECRET` to the Rails environment (web + any job runners that dispatch tasks).
- [ ] Add `AGENT_RUNNER_SECRET` to the agent-runner environment. Must be byte-identical to the Rails value — the secret is used for both HMAC signing and HKDF key derivation for token encryption.
- [ ] Determine `INTERNAL_ALLOWED_IPS` for Rails (agent-runner container's IP or the Docker network CIDR, e.g., `172.16.0.0/12`). Add to the Rails environment.
- [ ] Set `HARMONIC_HOSTNAME` in the agent-runner environment to the **bare base domain**, same value as Rails `HOSTNAME` (e.g., `harmonic.com` — NOT `app.harmonic.com`). Agent-runner prepends the tenant subdomain.
- [ ] Set `HARMONIC_INTERNAL_URL` in the agent-runner environment (direct TCP to Rails, e.g., `http://web:3000`). Must bypass the public reverse proxy — the proxy blocks `/internal/*` with 403.
- [ ] Set LLM provider config in agent-runner environment: `LLM_GATEWAY_MODE` (`litellm` or `stripe_gateway`), and `STRIPE_GATEWAY_KEY` if `stripe_gateway`. `LLM_BASE_URL` is optional (auto-defaults by mode).
- [ ] Confirm the reverse proxy blocks external `/internal/*` (see `CaddyfileGenerator#subdomain_block`).
- [ ] Confirm `/internal/*` paths are excluded from `force_ssl` redirect in `production.rb` (already configured — verify on deploy).
- [ ] Run migration adding `ai_agent_task_run_id` to `api_tokens`.

**Deploy:**
- [ ] Deploy Rails with new dispatch service, internal controller, and migration applied.
- [ ] Deploy the agent-runner container. Start with a single replica; resource budget ~200-500 MB memory for hundreds of concurrent tasks.
- [ ] Verify agent-runner connects to Redis and establishes the consumer group (default: `agent_runner` on stream `agent_tasks`). Check startup logs.

**Verify (before enabling real traffic):**
- [ ] From a Rails console on production, pick or create a non-destructive test task and dispatch: `AgentRunnerDispatchService.dispatch(task_run)`. Confirm the runner picks it up, steps are persisted, and `/complete` writes final state.
- [ ] Check `/system-admin/agent-runner` shows non-zero `totalTasksProcessed` and a recent `lastTaskAt`.
- [ ] Confirm an external `curl https://<host>/internal/agent-runner/tasks/foo/claim` returns **403 from the proxy** (not reaching Rails).
- [ ] Confirm an unsigned request through the internal network returns **401** from `Internal::BaseController`.

**Rollout:**
- [ ] Confirm `ghcr.io/ibis-coordination/harmonic-agent-runner` image is published for this version (docker-publish workflow now builds it alongside the Rails image).
- [ ] Deploy Rails + agent-runner together. Phase 2 removed the old `AgentQueueProcessorJob`, so there is no Sidekiq fallback — agent-runner must be healthy for any new tasks to run.
- [ ] **Re-dispatch stale queued tasks**: run `docker compose exec web bundle exec rake agent_runner:redispatch_queued`. Any tasks left in `status=queued` from before the cutover were never published to the Redis stream and will otherwise sit orphaned.
- [ ] Validate: trigger a test task (via `/ai-agents/<handle>/runs` or an @ mention) and confirm it flows through agent-runner — check `/system-admin/agent-runner` for non-zero `totalTasksProcessed` and recent `lastTaskAt`, and confirm the task run shows steps + final message.
- [ ] Monitor for billing-attribution parity (same `stripe_customer_id` stamped on task runs, same tokens counted).

**Rollback:**
- Flip the feature flag back to Sidekiq dispatch. Agent-runner can keep running — idle consumers are harmless.
- If agent-runner itself misbehaves, stop the container. In-flight tasks become stuck; the stuck-task recovery job marks them failed after the timeout.

---

## Security checklist

Every security mechanism from the current implementation must be preserved:

| Mechanism | Current location | agent-runner equivalent |
|-----------|-----------------|------------------------|
| Tenant exists + agents enabled | AgentQueueProcessorJob:17-22 | dispatch_to_agent_runner (Rails-side, before stream publish) |
| Agent not suspended/archived | AgentQueueProcessorJob:101-119 | dispatch_to_agent_runner + preflight double-check |
| Billing customer active | AgentQueueProcessorJob:125-135 | dispatch_to_agent_runner + preflight double-check |
| Credit balance > 0 | AgentQueueProcessorJob:141-153 | preflight endpoint re-checks |
| Stripe customer ID stamped | AgentQueueProcessorJob:138 | dispatch_to_agent_runner (Rails-side) |
| Ephemeral token lifecycle | MarkdownUiService:73-83 | Token created at dispatch, destroyed at complete/fail, cleaned by cron |
| Token not plaintext in Redis | N/A (in-process) | Encrypted with AES-256-GCM (key derived from AGENT_RUNNER_SECRET via HKDF) in stream payload; decrypted only by agent-runner |
| Internal API auth | N/A (in-process) | `Internal::BaseController`: IP restriction + HMAC-SHA256 on /internal/* routes |
| Agent API auth | Bearer token via ApplicationController | Unchanged — agent requests go through ApplicationController with Bearer token |
| Tenant isolation | Subdomain-based via ApplicationController | Agent API: same (Bearer token + subdomain). Internal API: `BaseController` resolves tenant from subdomain via `Tenant.scope_thread_to_tenant` |
| SSL in production | `config.force_ssl` | Agent API: `X-Forwarded-Proto: https` (trusted private network). Internal API: `/internal/*` excluded from SSL redirect |
| Capability enforcement | CapabilityCheck middleware | Unchanged — runs on every Rails API request (agent API goes through ApplicationController) |
| Identity prompt leakage | IdentityPromptLeakageDetector | Ported to agent-runner core/ (pure functions) |
| Scratchpad sanitization | AgentNavigator:334,338 | Ported to agent-runner core/ (control char removal, 10KB truncation) |
| Action validation | AgentNavigator:194-195 | Agent-runner validates against available actions from page |
| Max steps limit | AiAgentTaskRun validation (1-50) | Enforced in agent loop (from task payload) |
| Stuck task recovery | AgentQueueProcessorJob:73-95 | Rails periodic job checks for no recent step update |
| Rate limiting (3/min per agent rule) | AutomationDispatcher:82-99 | Unchanged — enforced before task creation |
| Chain depth/loop protection | AutomationContext:90-124 | Unchanged — enforced before task creation |
| Tenant rate limit (100/min) | AutomationDispatcher:129-139 | Unchanged — enforced before task creation |
| One task per agent | AgentQueueProcessorJob:50-55 (row lock) | In-memory agent lock set in agent-runner |
| Parent automation notification | AgentQueueProcessorJob:196 | /complete and /fail endpoints call notify_parent_automation_runs! |

---

## What this doesn't change

- **User experience:** Same agent UI, same task runs, same results view
- **Agent configuration:** Identity prompts, capabilities, scratchpad — all the same
- **Automation system:** Same triggers, same task creation flow, same rate limits
- **Billing:** Same Stripe gateway integration, same cost tracking, same credit balance checks
- **External agents:** MCP server still works for anyone running their own agent setup
- **Capability enforcement:** Same middleware, same allowed/blocked/grantable lists

---

## Out of Scope

- Public task lifecycle API for external agents (revisit if demand emerges)
- MCP server task lifecycle tools (revisit after agent-runner is stable)
- Trio / in-app assistant (will use agent-runner once built, but is a separate feature)
- Chat-style agent interaction UI (product feature, builds on agent-runner)
- Multi-instance agent-runner (single process is sufficient; add Redis-based agent locks if needed later)
- Actual cost tracking per task run (investigate whether Stripe AI Gateway returns per-request cost data or supports metadata for attribution; if so, backfill `estimated_cost_usd` with real costs)

---

## Order of Operations

1. **Phase 1** — Build agent-runner. Deploy alongside Sidekiq job with feature flag.
2. **Phase 2** — Once validated, remove Ruby agent execution code and switch fully to agent-runner.
3. **Phase 3** — Delete harmonic-agent.
4. **Phase 4** — Clean up mcp-server.

Phases 3 and 4 are independent and can happen any time.
