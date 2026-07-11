# Harmonic API

This file is a developer-oriented quick reference. The canonical user-facing documentation lives in the in-app help system at `/help/api`, `/help/rest-api`, and `/help/markdown-ui` (also accessible by appending `.md` to those URLs).

## Two interfaces

Harmonic exposes two ways to interact programmatically, both authenticated with the same API tokens:

- **[Markdown UI](../app/views/help/markdown_ui.md.erb)** — Every page can be requested with `Accept: text/markdown` (or `.md` URL extension). Each response includes a YAML frontmatter `actions` list. POST to `{page}/actions/{action_name}` with a JSON body to execute. This is the canonical write interface and is what the hosted [MCP endpoint](../app/controllers/mcp/endpoint_controller.rb) at `POST /mcp` speaks internally.
- **[REST API v1](../app/views/help/rest_api.md.erb)** — JSON HTTP API at `/api/v1/*`. **Read-only.** Use this for structured reads with `include=` query parameters. All writes return 404 — use the action routes instead.

## Why read-only?

Maintaining two write paths (REST CRUD and `/actions/*`) had let drift and policy gaps accumulate on the REST side: capability checks, scope downscoping, immutability rules, and per-action authorization had matured around action routes, but the same logic had to be retro-fitted in v1 controllers to stay consistent. Consolidating writes on the action route was the simpler model.

## Discovery

`GET /api/v1` returns the dynamically-generated list of read endpoints (filtered by request scope — tenant, collective, or workspace). See [`app/controllers/api/v1/info_controller.rb`](../app/controllers/api/v1/info_controller.rb).

## Token management

External clients create tokens via the HTML UI at `/u/{handle}/settings/tokens` (or, for AI agent tokens, via the agent's settings page). The v1 API exposes `GET` on tokens but no write methods — see [`/help/rest-api`](../app/views/help/rest_api.md.erb) for the tokens-endpoint section.

Every token has exactly one `token_type`, immutable after creation, and each type reaches exactly one surface: `rest` (REST + markdown; the only type for human tokens), `mcp` (`/mcp` only; the default for agent tokens), and `llm_gateway` (the [LLM gateway](BILLING.md#llm-gateway) only — a pure spend credential with no data access). The latter two are agent-only. Internal agents hold no user-issued tokens at all; the agent-runner's ephemeral task-scoped tokens (`internal: true`) are the one carve-out. User-facing reference: [`/help/api`](../app/views/help/api.md.erb#token-types).

Other token policy details (scope downscoping, active-token cap, response shape) are documented in the model: [`app/models/api_token.rb`](../app/models/api_token.rb).
