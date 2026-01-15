# Harmonic Agent

An autonomous AI agent service that responds to activity in Harmonic via webhooks. When triggered, the agent wakes up, explores the app through Harmonic's markdown API, and takes actions like reading notes, voting on decisions, and responding to mentions.

## Architecture

The agent uses [Effect.js](https://effect.website/) for functional programming with typed errors and dependency injection. Key components:

- **HTTP Server** (Hono) - Receives webhooks from Harmonic
- **Webhook Queue** - Buffers incoming webhooks for processing
- **MCP Client** - HTTP client for Harmonic's markdown API
- **AI Provider** - Abstraction over Claude/OpenAI for decision making
- **Agent Loop** - OODA loop (Observe → Orient → Decide → Act)

## Prerequisites

- Node.js 20+
- Access to a Harmonic instance with API enabled
- An Anthropic API key (or OpenAI API key)
- A publicly accessible URL for receiving webhooks (or ngrok for local development)

## Setup

### 1. Install Dependencies

```bash
cd harmonic-agent
npm install
```

### 2. Get Credentials from Harmonic

You'll need the following from your Harmonic administrator or the Harmonic settings UI:

1. **API Token** - An API token with appropriate scopes (`read:all`, `create:all`, `update:all`)
2. **Webhook Secret** - Created when setting up a webhook that points to your agent

To set up the webhook in Harmonic:
- Navigate to your studio's settings or admin panel
- Create a new webhook pointing to your agent's URL (e.g., `https://your-agent.example.com/webhook`)
- Select the events you want to subscribe to (e.g., `note.created`, `decision.created`, or `*` for all)
- Copy the webhook secret

### 3. Configure Environment

Copy the example environment file:

```bash
cp .env.example .env
```

Edit `.env` with your credentials:

```env
# HTTP Server
PORT=3001
HOST=0.0.0.0

# Harmonic Connection
HARMONIC_BASE_URL=https://your-tenant.harmonic.example.com
HARMONIC_API_TOKEN=<your-api-token>
WEBHOOK_SECRET=<your-webhook-secret>

# AI Provider
AI_PROVIDER=claude
ANTHROPIC_API_KEY=<your-anthropic-key>
AI_MODEL=claude-sonnet-4-20250514

# Agent Limits
MAX_TURNS=20
MAX_TOKENS_PER_SESSION=100000
SESSION_TIMEOUT_MS=300000
```

### 4. Deploy the Agent

#### Local Development with ngrok

For local testing, use ngrok to expose your agent:

```bash
# Start the agent
npm run dev

# In another terminal, expose it via ngrok
ngrok http 3001
```

Use the ngrok URL (e.g., `https://abc123.ngrok.io/webhook`) when creating your webhook in Harmonic.

#### Production Deployment

Deploy the agent as a Node.js service:

```bash
npm run build
npm start
```

Common deployment options:
- **Docker** - Use the included Dockerfile (if available) or containerize the Node.js app
- **Cloud Run / App Engine** - Deploy as a containerized service
- **EC2 / VPS** - Run with a process manager like PM2
- **Railway / Render / Fly.io** - Deploy directly from the repository

Ensure your deployment:
- Has a publicly accessible HTTPS URL for the webhook endpoint
- Has the environment variables configured
- Can make outbound HTTPS requests to your Harmonic instance

### 5. Verify the Setup

Check the agent's health endpoint:

```bash
curl https://your-agent.example.com/health
# {"status":"ok"}
```

Create activity in Harmonic (e.g., create a note or mention the agent) and watch the agent logs to confirm it receives and processes webhooks.

## Configuration Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | HTTP server port | `3001` |
| `HOST` | HTTP server host | `0.0.0.0` |
| `HARMONIC_BASE_URL` | Harmonic app URL | Required |
| `HARMONIC_API_TOKEN` | API token for authentication | Required |
| `WEBHOOK_SECRET` | Secret for verifying webhook signatures | Required |
| `AI_PROVIDER` | AI provider (`claude` or `openai`) | `claude` |
| `ANTHROPIC_API_KEY` | Anthropic API key (if using Claude) | Required if `AI_PROVIDER=claude` |
| `OPENAI_API_KEY` | OpenAI API key (if using OpenAI) | Required if `AI_PROVIDER=openai` |
| `AI_MODEL` | Model to use | `claude-sonnet-4-20250514` |
| `MAX_TURNS` | Maximum turns per session | `20` |
| `MAX_TOKENS_PER_SESSION` | Token limit per session | `100000` |
| `SESSION_TIMEOUT_MS` | Session timeout in milliseconds | `300000` |

## Agent Behavior

When triggered by a webhook, the agent:

1. **Navigates to `/notifications`** to see what needs attention
2. **Explores** studios, cycles, notes, decisions, and commitments
3. **Takes actions** like:
   - Confirming read on notes
   - Voting on decisions
   - Adding comments
   - Sending heartbeats for participation
4. **Stops** when there's nothing more to do, or when limits are reached

The agent uses the same markdown API that the MCP server uses, so it sees exactly what a human would see when browsing Harmonic.

## Webhook Events

The agent responds to any webhook event, but typically you'll want to subscribe to:

- `note.created` - New notes posted
- `decision.created` - New decisions started
- `commitment.created` - New commitments made
- `vote.created` - Votes cast on decisions
- `*` - All events

## Multiple Studios

To have the agent respond to events in multiple studios:

1. **Create one webhook per studio** - Each scoped to a specific studio
2. **Create one global webhook** - Scoped to receive events from all studios

The agent will explore all studios it has access to (those with API enabled for your token) regardless of which studio triggered the webhook.

## Troubleshooting

### Webhook not received

1. Verify your agent's URL is publicly accessible
2. Check that the webhook is enabled in Harmonic
3. Confirm the webhook URL matches your agent's `/webhook` endpoint
4. Check your agent logs for incoming requests

### Agent can't access studio

Your API token may not have access to the studio, or the studio may not have API access enabled. Contact your Harmonic administrator.

### Signature verification failed

Ensure `WEBHOOK_SECRET` in your `.env` matches the webhook's secret in Harmonic.

### Connection timeout

- Verify `HARMONIC_BASE_URL` is correct and accessible from your agent's network
- Check for firewall rules blocking outbound HTTPS requests

## Development

### Project Structure

```
harmonic-agent/
├── src/
│   ├── agent/           # Agent loop and context
│   ├── ai/              # AI provider abstraction
│   ├── config/          # Configuration with Effect Schema
│   ├── errors/          # Typed error classes
│   ├── http/            # HTTP server and webhook verification
│   ├── mcp/             # MCP client for Harmonic API
│   ├── queue/           # Webhook queue
│   ├── index.ts         # Entry point
│   └── main.ts          # Program composition
├── .env.example
├── package.json
└── tsconfig.json
```

### Run Tests

```bash
npm test
```

### Adding New AI Providers

1. Create a new file in `src/ai/` (e.g., `GeminiProvider.ts`)
2. Implement the `AiProvider` interface
3. Add the provider to `createAiProviderLayer` in `src/main.ts`
4. Update the config schema to accept the new provider name
