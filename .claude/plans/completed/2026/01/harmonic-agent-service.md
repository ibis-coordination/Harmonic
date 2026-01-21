# Harmonic Agent Service - Implementation Plan

A standalone TypeScript app using Effect.js that receives webhooks from Harmonic, wakes up an AI agent, and lets the agent autonomously explore and act using Harmonic's MCP interface.

## Architecture Overview

```
┌─────────────────┐     webhook     ┌──────────────────────────────────┐
│    Harmonic     │ ──────────────► │     Harmonic Agent Service       │
│   (Rails app)   │                 │                                  │
└─────────────────┘                 │  ┌─────────────┐                 │
        ▲                           │  │ HTTP Server │ (webhook recv)  │
        │                           │  └──────┬──────┘                 │
        │  MCP (navigate/           │         ▼                        │
        │  execute_action)          │  ┌─────────────┐                 │
        │                           │  │    Queue    │ (in-memory)     │
        └───────────────────────────┤  └──────┬──────┘                 │
                                    │         ▼                        │
                                    │  ┌─────────────┐                 │
                                    │  │ Agent Loop  │ ◄── AI Provider │
                                    │  └─────────────┘    (Claude/GPT) │
                                    └──────────────────────────────────┘
```

## Project Structure

```
harmonic-agent/
├── src/
│   ├── index.ts                  # Entry point
│   ├── main.ts                   # Effect program composition
│   │
│   ├── config/
│   │   └── Config.ts             # Configuration schema & service
│   │
│   ├── http/
│   │   ├── HttpServer.ts         # Hono HTTP server
│   │   └── WebhookVerification.ts # HMAC-SHA256 verification
│   │
│   ├── queue/
│   │   └── WebhookQueue.ts       # In-memory queue service
│   │
│   ├── mcp/
│   │   └── McpClient.ts          # HTTP client for Harmonic MCP
│   │
│   ├── ai/
│   │   ├── AiProvider.ts         # Abstract provider interface
│   │   ├── ClaudeProvider.ts     # Claude implementation
│   │   └── OpenAiProvider.ts     # OpenAI implementation
│   │
│   ├── agent/
│   │   ├── AgentLoop.ts          # Main agent loop
│   │   ├── AgentContext.ts       # System prompt & tools
│   │   └── AgentWorker.ts        # Queue consumer
│   │
│   └── errors/
│       └── Errors.ts             # Typed error classes
│
├── package.json
├── tsconfig.json
├── Dockerfile
└── docker-compose.yml
```

## Core Effect Services

### 1. Config Service
- Load from environment variables
- Schema validation with `@effect/schema`
- Fields: port, harmonicBaseUrl, harmonicApiToken, webhookSecret, aiProvider, apiKeys, maxTurns, etc.

### 2. HTTP Server (Hono)
- `POST /webhook` - receives Harmonic webhooks
- `GET /health` - health check
- Verifies HMAC-SHA256 signature before accepting

### 3. Webhook Queue
- In-memory Effect Queue
- Holds webhook payloads waiting for agent processing
- Simple FIFO, single consumer

### 4. MCP Client
- HTTP client that calls Harmonic directly (no MCP SDK needed)
- `navigate(path)` → GET with `Accept: text/markdown`
- `executeAction(action, params)` → POST to `/actions/{action}`
- Tracks `currentPath` in state

### 5. AI Provider
- Abstract interface for `chat(messages, tools) → response`
- ClaudeProvider: Uses `@anthropic-ai/sdk`
- OpenAiProvider: Uses `openai` SDK
- Both support tool use/function calling

### 6. Agent Loop
- Triggered by queue item
- Initial action: navigate to `/notifications`
- Loop: AI decides → tool call → execute → feed result back
- Stops when AI returns `end_turn` or limits reached

## Webhook Signature Verification

Based on `app/services/webhook_delivery_service.rb:77-78`:

```typescript
function verify(body: string, timestamp: string, signature: string, secret: string): boolean {
  const expected = crypto.createHmac("sha256", secret)
    .update(`${timestamp}.${body}`)
    .digest("hex")
  const actual = signature.replace(/^sha256=/, "")
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(actual))
}
```

Headers from Harmonic:
- `X-Harmonic-Signature`: `sha256=<hex>`
- `X-Harmonic-Timestamp`: Unix timestamp
- `X-Harmonic-Event`: Event type (e.g., `note.created`)
- `X-Harmonic-Delivery`: Delivery UUID

## Agent Loop Design

```
1. WAKE UP ─── Webhook received, queued
       │
       ▼
2. NAVIGATE ── Agent goes to /notifications
       │
       ▼
3. OBSERVE ─── AI reads markdown content
       │
       ▼
4. DECIDE ──── AI chooses: navigate elsewhere, execute action, or stop
       │
       ├── tool_use(navigate) ───► Execute, goto 3
       ├── tool_use(execute_action) ► Execute, goto 3
       └── end_turn ─────────────────► Done
```

## Tool Definitions

Two tools exposed to the AI (matching Harmonic MCP):

```typescript
const tools = [
  {
    name: "navigate",
    description: "Navigate to a URL in Harmonic. Returns markdown content and available actions.",
    input_schema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Relative path (e.g., '/studios/team/n/abc123')" }
      },
      required: ["path"]
    }
  },
  {
    name: "execute_action",
    description: "Execute an action at the current URL. Must call navigate first.",
    input_schema: {
      type: "object",
      properties: {
        action: { type: "string", description: "Action name from available actions" },
        params: { type: "object", description: "Action parameters" }
      },
      required: ["action"]
    }
  }
]
```

## System Prompt

Use `mcp-server/CONTEXT.md` as the foundation, plus:

```
You are an AI agent participating in a Harmonic studio.

You've been woken up by activity. Your job is to:
1. Check your notifications at /notifications
2. Explore items that need your attention
3. Take appropriate actions (comment, vote, commit, etc.)
4. Stop when you've addressed what needs attention

Guidelines:
- Be helpful and constructive
- Don't spam - be thoughtful
- Navigate before acting to see available actions
- End your session when done (stop calling tools)
```

## Configuration

```bash
# HTTP
PORT=3001
HOST=0.0.0.0

# Harmonic
HARMONIC_BASE_URL=https://acme.example.com
HARMONIC_API_TOKEN=<bearer token from Harmonic>
WEBHOOK_SECRET=<secret from webhook config in Harmonic>

# AI Provider
AI_PROVIDER=claude  # or "openai"
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
AI_MODEL=claude-sonnet-4-20250514

# Agent Limits
MAX_TURNS=20
MAX_TOKENS_PER_SESSION=100000
SESSION_TIMEOUT_MS=300000
```

## Dependencies

```json
{
  "dependencies": {
    "effect": "^3.12.0",
    "@effect/schema": "^0.75.0",
    "hono": "^4.7.0",
    "@hono/node-server": "^1.14.0",
    "@anthropic-ai/sdk": "^0.37.0",
    "openai": "^4.77.0"
  },
  "devDependencies": {
    "typescript": "^5.7.0",
    "vitest": "^3.0.0",
    "tsx": "^4.19.0",
    "@types/node": "^22.10.0"
  }
}
```

## Implementation Phases

### Phase 1: Project Setup
- Initialize TypeScript project with Effect.js
- Config service with schema validation
- Basic Hono HTTP server with health endpoint
- Error types

### Phase 2: Webhook Handling
- Signature verification function
- Webhook endpoint handler
- In-memory queue
- Tests with mock webhooks

### Phase 3: MCP Client
- HTTP client for navigate/execute_action
- State management (currentPath)
- Error handling
- Tests

### Phase 4: AI Providers
- Abstract AiProvider interface
- Claude implementation with tool use
- OpenAI implementation with function calling
- Tests with mock responses

### Phase 5: Agent Loop
- Agent session state management
- Main loop with turn/token limits
- Tool execution and result formatting
- System prompt from CONTEXT.md
- Integration tests

### Phase 6: Docker
- Multi-stage Dockerfile
- docker-compose.yml for local dev
- Graceful shutdown

## Verification

1. **Unit tests**: Run `npm test` - verify each service in isolation
2. **Manual test**:
   - Start app with `docker compose up`
   - Create webhook in Harmonic pointing to `http://host.docker.internal:3001/webhook`
   - Create a note in Harmonic to trigger webhook
   - Observe agent checking notifications and responding
3. **Check logs**: Agent should navigate to /notifications, explore content, take actions

## Key Files to Reference

- `app/services/webhook_delivery_service.rb` - Signature verification
- `mcp-server/src/handlers.ts` - MCP client patterns
- `mcp-server/CONTEXT.md` - Agent context/system prompt
