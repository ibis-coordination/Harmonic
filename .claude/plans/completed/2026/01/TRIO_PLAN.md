# Trio: OpenAI-Compatible Voting Ensemble Service

## Goal

Create a standalone Python microservice that implements the voting ensemble pattern behind an OpenAI-compatible API. Any client that can talk to OpenAI can use Trio as a drop-in replacement, getting consensus responses from multiple models.

**Decisions made:**
- Location: `trio/` directory in this repo
- Voting model: Same models that generate responses
- Streaming: Skip for MVP
- Detailed response: Custom `X-Trio-Details` header (JSON)

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

## Files to Create

### 1. trio/pyproject.toml

Dependencies:
- `fastapi` - Web framework
- `uvicorn` - ASGI server
- `httpx` - Async HTTP client
- `pydantic` - Data validation (comes with FastAPI)
- `pydantic-settings` - Settings from env vars

### 2. trio/src/config.py

Settings from environment:
```python
class Settings(BaseSettings):
    trio_models: str = "default,llama3.2-3b,mistral"  # Comma-separated
    trio_backend_url: str = "http://litellm:4000"
    trio_port: int = 8000
    trio_timeout: int = 60
```

### 3. trio/src/models.py

Pydantic models matching OpenAI API:
- `ChatMessage` - role, content
- `ChatCompletionRequest` - model, messages, max_tokens, temperature, etc.
- `ChatCompletionResponse` - id, object, created, model, choices, usage
- `VotingDetails` - candidates array with model, response, accepted, preferred

### 4. trio/src/llm.py

Async client for backend LLM calls:
```python
async def fetch_completion(
    backend_url: str,
    model: str,
    messages: list[ChatMessage],
    max_tokens: int = 500,
    temperature: float = 0.7,
) -> str | None
```

### 5. trio/src/voting.py

Core voting logic (port from VotingCompletionClient):
- `generate_responses()` - fan out to all models in parallel
- `run_acceptance_voting()` - each model votes on all responses
- `get_voter_votes()` - parse ACCEPTED/PREFERRED from model response
- `pick_winner()` - rank by acceptance DESC, preference DESC

### 6. trio/src/main.py

FastAPI app:
```python
@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest) -> ChatCompletionResponse:
    # 1. Generate responses from all models
    # 2. Run voting
    # 3. Build OpenAI-format response
    # 4. Add X-Trio-Details header with voting metadata

@app.get("/v1/models")
async def list_models():
    return {"data": [{"id": "trio", "object": "model"}]}

@app.get("/health")
async def health():
    return {"status": "ok"}
```

### 7. trio/Dockerfile

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml .
RUN pip install .
COPY src/ src/
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### 8. docker-compose.yml (modify)

Add Trio service under "llm" profile:
```yaml
trio:
  build: ./trio
  profiles: ["llm"]
  ports:
    - "8000:8000"
  depends_on:
    - litellm
  environment:
    TRIO_MODELS: "default,llama3.2-3b,mistral"
    TRIO_BACKEND_URL: "http://litellm:4000"
```

### 9. trio/README.md

Usage documentation.

## Implementation Order

1. Create `trio/` directory structure
2. Create `pyproject.toml` with dependencies
3. Create `src/config.py` - settings
4. Create `src/models.py` - Pydantic models
5. Create `src/llm.py` - backend client
6. Create `src/voting.py` - voting logic
7. Create `src/main.py` - FastAPI app
8. Create `Dockerfile`
9. Update `docker-compose.yml` to add trio service
10. Create `README.md`

## API Contract

### Request (standard OpenAI)
```json
POST /v1/chat/completions
{
  "model": "trio",
  "messages": [
    {"role": "user", "content": "What is 2+2?"}
  ],
  "max_tokens": 500
}
```

### Response (standard OpenAI + custom header)
```json
{
  "id": "trio-abc123",
  "object": "chat.completion",
  "created": 1705000000,
  "model": "trio",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "4"},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11}
}
```

### X-Trio-Details Header (JSON)
```json
{
  "winner_index": 0,
  "candidates": [
    {"model": "default", "response": "4", "accepted": 3, "preferred": 2},
    {"model": "llama3.2-3b", "response": "The answer is 4.", "accepted": 3, "preferred": 1},
    {"model": "mistral", "response": "2+2=4", "accepted": 2, "preferred": 0}
  ]
}
```

## Verification

1. Build and start services:
   ```bash
   docker compose --profile llm build trio
   docker compose --profile llm up -d
   ```

2. Pull required Ollama models (if not already):
   ```bash
   docker compose exec ollama ollama pull llama3.2:1b
   docker compose exec ollama ollama pull llama3.2:3b
   docker compose exec ollama ollama pull mistral
   ```

3. Test health endpoint:
   ```bash
   curl http://localhost:8000/health
   ```

4. Test chat completion:
   ```bash
   curl -X POST http://localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "trio", "messages": [{"role": "user", "content": "What is 2+2?"}]}' \
     -v  # to see X-Trio-Details header
   ```

5. Test with OpenAI Python client:
   ```python
   from openai import OpenAI
   client = OpenAI(base_url="http://localhost:8000/v1", api_key="unused")
   response = client.chat.completions.create(
       model="trio",
       messages=[{"role": "user", "content": "What is 2+2?"}]
   )
   print(response.choices[0].message.content)
   ```

## Key Reference

- Voting logic: [app/services/voting_completion_client.rb](app/services/voting_completion_client.rb)
- LiteLLM config: [config/litellm_config.yaml](config/litellm_config.yaml)
- Docker setup: [docker-compose.yml](docker-compose.yml)
