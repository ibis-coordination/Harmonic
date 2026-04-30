# Plan: Add `search` and `get_help` agent tools

## Context

Agents currently interact with Harmonic using only `navigate` and `execute_action`. Common patterns like searching and reading documentation require agents to know the right URL to navigate to. Adding dedicated `search` and `get_help` tools makes these actions more discoverable (the tool definitions themselves serve as documentation) and saves agents a step.

Both tools are thin wrappers — they construct a path and delegate to the same navigate logic. They must be added in two places:

1. **agent-runner** — internal agents that run tasks and chat turns via the agent-runner service
2. **mcp-server** — external agents (e.g., Claude Code) that connect via MCP

The two systems have different architectures:
- **agent-runner**: Effect-based, tools defined in `AgentContext.ts` as OpenAI-compatible function defs, parsed in `ActionParser.ts`, dispatched in `AgentLoop.ts`
- **mcp-server**: MCP SDK, tools registered via `server.registerTool()` in `index.ts`, handlers in `handlers.ts`

Both delegate to the same Rails markdown API endpoints:
- Search: `GET /search?q={query}` (also available as `POST /search/actions/search` with `{query}` param)
- Help: `GET /help/{topic}` where topic is one of: `privacy`, `collectives`, `notes`, `reminder-notes`, `table-notes`, `decisions`, `commitments`, `cycles`, `search`, `links`, `agents`, `api`

## Implementation

### agent-runner

#### 1. Tool definitions — `agent-runner/src/core/AgentContext.ts`

Add two entries to `AGENT_TOOLS`:

```typescript
{
  type: "function",
  function: {
    name: "search",
    description: "Search Harmonic for notes, decisions, commitments, and people.",
    parameters: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Search query. Supports filters: type:note, type:decision, type:commitment, status:open, cycle:current, creator:@handle, collective:handle",
        },
      },
      required: ["query"],
    },
  },
},
{
  type: "function",
  function: {
    name: "get_help",
    description: "Read Harmonic documentation for a topic.",
    parameters: {
      type: "object",
      properties: {
        topic: {
          type: "string",
          description: "Topic name. Available: collectives, notes, reminder-notes, table-notes, decisions, commitments, cycles, search, links, agents, api, privacy",
        },
      },
      required: ["topic"],
    },
  },
},
```

Update `TASK_TOOLS` and `CHAT_TOOLS` prompt strings to mention the new tools (e.g., "You have four tools: `navigate`, `execute_action`, `search`, and `get_help`." for task mode, five for chat mode).

#### 2. Action type + parse logic — `agent-runner/src/core/ActionParser.ts`

Add two variants to the `AgentAction` union:

```typescript
| { readonly type: "search"; readonly query: string }
| { readonly type: "get_help"; readonly topic: string }
```

Add two cases to the `parseToolCall` switch:
- `"search"`: validate `query` is a non-empty string
- `"get_help"`: validate `topic` is a non-empty string

#### 3. Dispatch — `agent-runner/src/services/AgentLoop.ts`

Add two cases to the action dispatch switch. Both delegate to `navigateTo` (same as navigate), so the agent sees page content + available actions:

```typescript
case "search": {
  yield* navigateTo(`/search?q=${encodeURIComponent(action.query)}`);
  toolResults.push(truncateContent(currentContent ?? ""));
  break;
}
case "get_help": {
  yield* navigateTo(`/help/${encodeURIComponent(action.topic)}`);
  toolResults.push(truncateContent(currentContent ?? ""));
  break;
}
```

#### 4. agent-runner tests

**`agent-runner/test/core/ActionParser.test.ts`**:
- Parsing `search` tool call with query
- Parsing `get_help` tool call with topic
- Error on empty query / empty topic

**`agent-runner/test/core/AgentContext.test.ts`**:
- Tool count assertion (2 → 4)
- Tool names assertion includes `search` and `get_help`

### mcp-server

#### 5. Handlers — `mcp-server/src/handlers.ts`

Add two handler functions that delegate to `handleNavigate`:

```typescript
export async function handleSearch(
  query: string,
  config: Config,
  state: State,
  fetchFn: typeof fetch = fetch
): Promise<ToolResult> {
  return handleNavigate(`/search?q=${encodeURIComponent(query)}`, config, state, fetchFn);
}

export async function handleGetHelp(
  topic: string,
  config: Config,
  state: State,
  fetchFn: typeof fetch = fetch
): Promise<ToolResult> {
  return handleNavigate(`/help/${encodeURIComponent(topic)}`, config, state, fetchFn);
}
```

#### 6. Tool registration — `mcp-server/src/index.ts`

Register both tools using `server.registerTool()` with the same descriptions/schemas as agent-runner:

```typescript
server.registerTool(
  "search",
  {
    description: "Search Harmonic for notes, decisions, commitments, and people.",
    inputSchema: {
      query: z.string().describe(
        "Search query. Supports filters: type:note, type:decision, type:commitment, status:open, cycle:current, creator:@handle, collective:handle"
      ),
    },
  },
  async ({ query }) => handleSearch(query, config, state)
);

server.registerTool(
  "get_help",
  {
    description: "Read Harmonic documentation for a topic.",
    inputSchema: {
      topic: z.string().describe(
        "Topic name. Available: collectives, notes, reminder-notes, table-notes, decisions, commitments, cycles, search, links, agents, api, privacy"
      ),
    },
  },
  async ({ topic }) => handleGetHelp(topic, config, state)
);
```

#### 7. mcp-server tests — `mcp-server/src/handlers.test.ts`

Add tests for both handlers:

**`handleSearch`**:
- Delegates to navigate with correct search URL
- Encodes query parameter
- Passes through errors from navigate

**`handleGetHelp`**:
- Delegates to navigate with correct help URL
- Encodes topic parameter
- Passes through errors from navigate

## Files to modify

| File | Change |
|------|--------|
| `agent-runner/src/core/AgentContext.ts` | Tool definitions + prompt text |
| `agent-runner/src/core/ActionParser.ts` | Type + parse logic |
| `agent-runner/src/services/AgentLoop.ts` | Dispatch |
| `agent-runner/test/core/ActionParser.test.ts` | Parse tests |
| `agent-runner/test/core/AgentContext.test.ts` | Tool definition tests |
| `mcp-server/src/handlers.ts` | Handler functions |
| `mcp-server/src/index.ts` | Tool registration |
| `mcp-server/src/handlers.test.ts` | Handler tests |

## Verification

```bash
# agent-runner
cd agent-runner && npm test && npm run typecheck && npm run build

# mcp-server
cd mcp-server && npm test && npm run typecheck && npm run build
```
