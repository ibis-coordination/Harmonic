# Trio

Trio is an ensemble of AI models that operates as a singular unified model itself. You can prompt Trio just as you would with any other AI model, but under the hood Trio uses multiple models to arrive at a single response to each prompt.

Because Trio uses multiple models, it is slower and more expensive to run than a single model, but the benefit is more consistent quality output. This is a good tradeoff for use cases where consistent quality is more important than speed or cost.

Trio exposes an OpenAI-compatible API, so any client that can talk to OpenAI can use Trio as a drop-in replacement.

## Recursion

Because Trio acts as a singular model from the client perspective, Trio can actually use other Trio instances as internal models in a recursive loop. This does multiply the cost and latency considerably, but this architecture enables hierarchical consensus: each sub-Trio reaches its own consensus, and then the top-level Trio selects among those consensus responses. This amplifies diversity (N Trio instances with M models each means N×M perspectives) and allows specialization, where different Trio instances can be tuned for different purposes (e.g., one optimized for creativity, another for factual accuracy, another for technical depth).

## How It Works

1. **Generate**: Trio sends the prompt to N configured models in parallel
2. **Aggregate**: Select the winning response using one of three methods:
   - **acceptance_voting** (default): Each model votes on all responses, winner has most acceptances
   - **random**: Randomly select one response
   - **judge**: A separate judge model evaluates and picks the best response
3. **Return**: The winning response is returned in OpenAI format

## Aggregation Methods

Trio supports multiple methods for selecting the best response from the ensemble:

### Acceptance Voting (default)

Each model evaluates all responses:
- **ACCEPTED**: Responses that adequately answer the question
- **PREFERRED**: The single best response from accepted ones

Winner is ranked by acceptance count DESC, then preference count DESC. This is the most thorough method but requires 2N model calls (N responses + N voting rounds).

### Random Selection

Randomly selects one of the generated responses. Fast and cheap (only N model calls), useful for:
- A/B testing different ensemble configurations
- When you want diversity over consistency
- Baseline comparisons against voting methods

### Judge Model

A separate "judge" model evaluates all responses and picks the best one. Requires N+1 model calls (N responses + 1 judge call). Good when:
- You have a high-quality model available as judge
- You want faster aggregation than acceptance voting
- The judge model is different from the ensemble models

## Pass-Through Mode

Trio also acts as a unified gateway. If you specify a non-trio model name (e.g., `"model": "mistral"`), Trio bypasses ensemble voting and forwards the request directly to that model via the backend. This lets clients use a single endpoint for both ensemble voting and direct model access.

```bash
# Ensemble voting (uses trio-1.0)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "trio-1.0", "messages": [{"role": "user", "content": "Hello!"}]}'

# Pass-through to specific model (no voting)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "mistral", "messages": [{"role": "user", "content": "Hello!"}]}'
```

## Quick Start

```bash
# Start all LLM services including Trio
docker compose --profile llm up -d

# Pull required Ollama models
docker compose exec ollama ollama pull llama3.2:1b
docker compose exec ollama ollama pull llama3.2:3b
docker compose exec ollama ollama pull mistral

# Test the health endpoint
curl http://localhost:8000/health

# Make a completion request
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "trio-1.0", "messages": [{"role": "user", "content": "What is 2+2?"}]}'
```

## API

### POST /v1/chat/completions

Standard OpenAI chat completions endpoint.

**Request:**
```json
{
  "model": "trio-1.0",
  "messages": [
    {"role": "user", "content": "What is 2+2?"}
  ],
  "max_tokens": 500,
  "temperature": 0.7
}
```

If no `trio_ensemble` is specified, Trio uses the default models from the `TRIO_MODELS` environment variable.

**With custom ensemble (`trio_ensemble`):**
```json
{
  "model": "trio-1.0",
  "messages": [
    {"role": "user", "content": "Explain quantum computing"}
  ],
  "trio_ensemble": [
    {"model": "llama3.2:1b", "system_prompt": "You are concise and direct. Keep answers brief."},
    {"model": "llama3.2:3b", "system_prompt": "You are detailed and thorough. Provide comprehensive explanations."},
    {"model": "mistral", "system_prompt": "You are creative and use analogies to explain complex topics."}
  ]
}
```

The `trio_ensemble` field gives full control over the ensemble. Each member has:
- `model` (required): The model name
- `system_prompt` (optional): Custom system prompt for this model

If you just want to specify models without custom prompts, omit `system_prompt`:
```json
{
  "trio_ensemble": [
    {"model": "llama3.2:1b"},
    {"model": "mistral"},
    {"model": "codellama"}
  ]
}
```

**Response:**
```json
{
  "id": "trio-abc123",
  "object": "chat.completion",
  "created": 1705000000,
  "model": "trio-1.0",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "4"},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11}
}
```

**X-Trio-Details Header:**

The response includes a custom header with aggregation details:
```json
{
  "winner_index": 0,
  "aggregation_method": "acceptance_voting",
  "candidates": [
    {"model": "default", "response": "4", "accepted": 3, "preferred": 2},
    {"model": "llama3.2-3b", "response": "The answer is 4.", "accepted": 3, "preferred": 1},
    {"model": "mistral", "response": "2+2=4", "accepted": 2, "preferred": 0}
  ]
}
```

**With aggregation method:**

Use `trio_aggregation_method` to specify how to select the winner:

```json
{
  "model": "trio-1.0",
  "messages": [{"role": "user", "content": "What is 2+2?"}],
  "trio_aggregation_method": "random"
}
```

**With judge model:**

When using `judge` aggregation, specify the judge model:

```json
{
  "model": "trio-1.0",
  "messages": [{"role": "user", "content": "Explain quantum computing"}],
  "trio_aggregation_method": "judge",
  "trio_judge_model": "claude-sonnet"
}
```

### GET /v1/models

List available models.

### GET /health

Health check endpoint.

## Configuration

Environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `TRIO_MODELS` | Comma-separated model names | `default,llama3.2-3b,mistral` |
| `TRIO_BACKEND_URL` | LiteLLM/Ollama URL | `http://litellm:4000` |
| `TRIO_PORT` | Service port | `8000` |
| `TRIO_TIMEOUT` | Request timeout (seconds) | `120` |
| `TRIO_AGGREGATION_METHOD` | Default aggregation method | `acceptance_voting` |
| `TRIO_JUDGE_MODEL` | Model for judge aggregation | (none) |

## Using with OpenAI Clients

Trio is compatible with any OpenAI client. Just point it at Trio's URL:

**Python:**
```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="unused")
response = client.chat.completions.create(
    model="trio-1.0",
    messages=[{"role": "user", "content": "What is 2+2?"}]
)
print(response.choices[0].message.content)
```

**curl:**
```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer unused" \
  -d '{"model": "trio-1.0", "messages": [{"role": "user", "content": "Hello!"}]}'
```

**With custom ensemble:**
```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "trio-1.0",
    "messages": [{"role": "user", "content": "Hello!"}],
    "trio_ensemble": [{"model": "llama3.2:1b"}, {"model": "mistral"}, {"model": "codellama"}]
  }'
```

## Architecture

```
Client → Trio (port 8000) → LiteLLM (port 4000) → Ollama/Claude/OpenAI
              ↓
         Fan out to N models
              ↓
         Collect responses
              ↓
         Voting round (each model votes)
              ↓
         Return winner in OpenAI format
```

## Development

```bash
# Install dependencies
cd trio
pip install -e ".[dev]"

# Run locally (requires LiteLLM backend)
TRIO_BACKEND_URL=http://localhost:4000 uvicorn src.main:app --reload

# Run tests
pytest

# Run type checker
mypy src/
```
