"""FastAPI application for Trio voting ensemble service."""

import json
import logging

import httpx
from fastapi import FastAPI, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .models import (
    ChatCompletionChoice,
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatMessage,
    EnsembleMember,
    ModelInfo,
    ModelListResponse,
)
from .voting import voting_completion

# Configure logging
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Model identifier with version for API responses
MODEL_ID = "trio-1.0"

# Maximum number of models allowed in a single ensemble request
# Based on research suggesting 3-7 is optimal; 9 allows for 3x3 hierarchical setups
MAX_ENSEMBLE_SIZE = 9

app = FastAPI(
    title="Trio",
    description="OpenAI-compatible voting ensemble service",
    version="0.1.0",
)

# Enable CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health() -> dict[str, str]:
    """Health check endpoint."""
    return {"status": "ok"}


@app.get("/v1/models")
async def list_models() -> ModelListResponse:
    """List available models (OpenAI-compatible)."""
    return ModelListResponse(
        data=[
            ModelInfo(id=MODEL_ID, owned_by="trio"),
        ]
    )


def is_trio_model(model: str) -> bool:
    """Check if the model name refers to Trio ensemble."""
    return model == "trio" or model.startswith("trio-")


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest, response: Response) -> ChatCompletionResponse:
    """Create a chat completion using voting ensemble (OpenAI-compatible).

    This endpoint is compatible with the OpenAI chat completions API.

    If model is "trio" or "trio-1.0", generates responses from multiple models,
    runs acceptance voting, and returns the winning response.

    If model is any other value (e.g., "mistral"), passes through directly to
    that model via the backend without ensemble voting.

    Voting details are included in the X-Trio-Details response header.
    """
    settings = get_settings()

    # Determine if this is a Trio ensemble request or pass-through
    if is_trio_model(request.model):
        # Trio ensemble mode
        if request.trio_ensemble:
            ensemble = request.trio_ensemble
        else:
            ensemble = [EnsembleMember(model=m) for m in settings.models]
        response_model = MODEL_ID
    else:
        # Pass-through mode: forward directly to the specified model
        ensemble = [EnsembleMember(model=request.model)]
        response_model = request.model

    # Validate ensemble size
    if len(ensemble) > MAX_ENSEMBLE_SIZE:
        raise HTTPException(
            status_code=400,
            detail=f"Ensemble size {len(ensemble)} exceeds maximum of {MAX_ENSEMBLE_SIZE} models",
        )

    # Determine aggregation method (request param overrides settings default)
    aggregation_method = request.trio_aggregation_method or settings.trio_aggregation_method
    judge_model = request.trio_judge_model or settings.trio_judge_model

    # Validate judge method has a judge_model
    if aggregation_method == "judge" and not judge_model:
        raise HTTPException(
            status_code=400,
            detail="trio_judge_model is required when using 'judge' aggregation method",
        )

    logger.info(
        f"Chat completion request: {len(request.messages)} messages, "
        f"ensemble: {[e.model for e in ensemble]}, aggregation: {aggregation_method}"
    )

    # Use httpx client with timeout
    async with httpx.AsyncClient(timeout=settings.trio_timeout) as client:
        winner_response, voting_details = await voting_completion(
            client,
            settings,
            request.messages,
            ensemble,
            request.max_tokens,
            request.temperature,
            aggregation_method,
            judge_model,
        )

    # Build OpenAI-compatible response
    completion_response = ChatCompletionResponse(
        model=response_model,
        choices=[
            ChatCompletionChoice(
                index=0,
                message=ChatMessage(role="assistant", content=winner_response),
                finish_reason="stop",
            )
        ],
    )

    # Add voting details to custom header
    response.headers["X-Trio-Details"] = json.dumps(voting_details.model_dump())

    return completion_response


if __name__ == "__main__":
    import uvicorn

    settings = get_settings()
    uvicorn.run(app, host="0.0.0.0", port=settings.trio_port)
