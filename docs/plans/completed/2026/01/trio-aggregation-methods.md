# Plan: Add Multiple Aggregation Methods to Trio

## Overview

Add configurable aggregation methods to Trio beyond the current acceptance voting. Initial methods:
1. **acceptance** (existing) - Models vote ACCEPTED/PREFERRED, ranked by counts
2. **random** - Randomly select from generated responses
3. **judge** - Use a separate judge model to pick the best response

## Current Architecture

- Aggregation logic: [voting.py:199-214](../../trio/src/voting.py#L199-L214) (`pick_winner()`)
- Request models: [models.py:24-39](../../trio/src/models.py#L24-L39) (`ChatCompletionRequest`)
- Config: [config.py:16-27](../../trio/src/config.py#L16-L27) (`Settings`)
- Main orchestrator: [voting.py:217-332](../../trio/src/voting.py#L217-L332) (`voting_completion()`)

## Implementation Plan

### Step 1: Add Configuration

**File: [trio/src/config.py](../../trio/src/config.py)**
- Add `trio_aggregation_method: str = "acceptance"` to `Settings`
- Add `trio_judge_model: str | None = None` for judge method

**File: [trio/src/models.py](../../trio/src/models.py)**
- Add `trio_aggregation_method: str | None = None` to `ChatCompletionRequest`
- Add `trio_judge_model: str | None = None` to `ChatCompletionRequest`
- Request params override environment defaults

### Step 2: Create Aggregation Module

**New file: [trio/src/aggregation.py](../../trio/src/aggregation.py)**

```python
# Strategy pattern for aggregation methods

class AggregationResult:
    winner_index: int
    method: str
    details: dict  # method-specific metadata

async def aggregate_random(responses: list[tuple[str, str]], **kwargs) -> AggregationResult:
    """Randomly select a response."""

async def aggregate_acceptance(responses, question, settings, **kwargs) -> AggregationResult:
    """Existing acceptance voting logic (moved from voting.py)."""

async def aggregate_judge(responses, question, judge_model, settings, **kwargs) -> AggregationResult:
    """Use a judge model to evaluate and select best response."""

async def aggregate(
    method: str,
    responses: list[tuple[str, str]],
    question: str,
    settings: Settings,
    **kwargs
) -> AggregationResult:
    """Dispatch to appropriate aggregation method."""
```

### Step 3: Implement Random Selection

Simple implementation:
```python
import random

async def aggregate_random(responses: list[tuple[str, str]], **kwargs) -> AggregationResult:
    winner_index = random.randint(0, len(responses) - 1)
    return AggregationResult(
        winner_index=winner_index,
        method="random",
        details={"selected_randomly": True},
    )
```

### Step 4: Implement Judge Model

Judge receives all responses and picks the best:
```python
async def aggregate_judge(
    responses: list[tuple[str, str]],
    question: str,
    judge_model: str,
    settings: Settings,
    **kwargs
) -> AggregationResult:
    # Build prompt showing all responses
    # Ask judge to pick best one (return number)
    # Parse response, return winner index
```

Judge prompt format:
```
A user asked: "<question>"

Here are N candidate responses:

Response 1:
<response>

---

Response 2:
<response>

...

Which response best answers the user's question? Consider accuracy,
completeness, and helpfulness. Reply with just the number (1, 2, etc.).
```

### Step 5: Update voting.py

**File: [trio/src/voting.py](../../trio/src/voting.py)**

- Move acceptance voting logic to `aggregation.py`
- Update `voting_completion()` to:
  1. Accept `aggregation_method` and `judge_model` params
  2. Call `aggregate()` dispatcher
  3. Include method info in `VotingDetails`

### Step 6: Update VotingDetails Model

**File: [trio/src/models.py](../../trio/src/models.py)**

Add to `VotingDetails`:
```python
class VotingDetails(BaseModel):
    winner_index: int
    candidates: list[Candidate]
    aggregation_method: str = "acceptance"  # New field
```

### Step 7: Update Main Endpoint

**File: [trio/src/main.py](../../trio/src/main.py)**

- Extract `trio_aggregation_method` and `trio_judge_model` from request
- Fall back to settings defaults
- Pass to `voting_completion()`

### Step 8: Add Tests

**File: [trio/tests/test_voting.py](../../trio/tests/test_voting.py)**

- Test random selection returns valid index
- Test judge model integration
- Test aggregation method fallback to env var default
- Test invalid aggregation method returns error

### Step 9: Update Documentation

**File: [trio/README.md](../../trio/README.md)**

- Add "Aggregation Methods" section explaining each method
- Document new environment variables (`TRIO_AGGREGATION_METHOD`, `TRIO_JUDGE_MODEL`)
- Add examples for each aggregation method in API section
- Update configuration table

**File: [.env.example](../../.env.example)**

- Add `TRIO_AGGREGATION_METHOD=acceptance`
- Add `TRIO_JUDGE_MODEL=` (empty default)

## Files to Modify

| File | Changes |
|------|---------|
| `trio/src/config.py` | Add `trio_aggregation_method`, `trio_judge_model` settings |
| `trio/src/models.py` | Add request params, update `VotingDetails` |
| `trio/src/aggregation.py` | **New file** - aggregation strategies |
| `trio/src/voting.py` | Refactor to use aggregation module |
| `trio/src/main.py` | Wire up new params |
| `trio/tests/test_voting.py` | Add tests for new methods |
| `trio/README.md` | Document new options |
| `.env.example` | Add new env vars |

## API Changes

**Request with aggregation method:**
```json
{
  "model": "trio-1.0",
  "messages": [{"role": "user", "content": "What is 2+2?"}],
  "trio_aggregation_method": "random"
}
```

**Request with judge model:**
```json
{
  "model": "trio-1.0",
  "messages": [{"role": "user", "content": "Explain quantum computing"}],
  "trio_aggregation_method": "judge",
  "trio_judge_model": "claude-sonnet"
}
```

**Updated X-Trio-Details response:**
```json
{
  "winner_index": 0,
  "aggregation_method": "acceptance",
  "candidates": [...]
}
```

## Verification

1. Run existing tests: `cd trio && pytest`
2. Start services: `docker compose --profile llm up -d`
3. Test acceptance (default):
   ```bash
   curl -X POST http://localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "trio-1.0", "messages": [{"role": "user", "content": "What is 2+2?"}]}'
   ```
4. Test random:
   ```bash
   curl -X POST http://localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "trio-1.0", "messages": [{"role": "user", "content": "What is 2+2?"}], "trio_aggregation_method": "random"}'
   ```
5. Test judge:
   ```bash
   curl -X POST http://localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "trio-1.0", "messages": [{"role": "user", "content": "What is 2+2?"}], "trio_aggregation_method": "judge", "trio_judge_model": "mistral"}'
   ```
6. Verify `X-Trio-Details` header includes `aggregation_method` field
