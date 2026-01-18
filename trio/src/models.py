"""Pydantic models for OpenAI-compatible API."""

import time
import uuid
from typing import Literal

from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    """A single message in the chat conversation."""

    role: Literal["system", "user", "assistant"]
    content: str


class EnsembleMember(BaseModel):
    """A model in the ensemble with optional custom system prompt."""

    model: str
    system_prompt: str | None = None


class ChatCompletionRequest(BaseModel):
    """Request body for /v1/chat/completions endpoint."""

    model: str = "trio"
    messages: list[ChatMessage]
    max_tokens: int = 500
    temperature: float = 0.7
    top_p: float | None = None
    n: int = 1
    stream: bool = False
    stop: str | list[str] | None = None
    presence_penalty: float = 0.0
    frequency_penalty: float = 0.0
    user: str | None = None
    # Trio-specific: specify ensemble members with optional per-model system prompts
    trio_ensemble: list[EnsembleMember] | None = None
    # Trio-specific: aggregation method ("acceptance_voting", "random", or "judge")
    trio_aggregation_method: str | None = None
    # Trio-specific: model to use for judge aggregation
    trio_judge_model: str | None = None


class ChatCompletionChoice(BaseModel):
    """A single completion choice in the response."""

    index: int
    message: ChatMessage
    finish_reason: Literal["stop", "length", "content_filter"] = "stop"


class UsageInfo(BaseModel):
    """Token usage information."""

    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0


class ChatCompletionResponse(BaseModel):
    """Response body for /v1/chat/completions endpoint."""

    id: str = Field(default_factory=lambda: f"trio-{uuid.uuid4().hex[:12]}")
    object: Literal["chat.completion"] = "chat.completion"
    created: int = Field(default_factory=lambda: int(time.time()))
    model: str  # Set by caller (e.g., "trio-1.0")
    choices: list[ChatCompletionChoice]
    usage: UsageInfo = Field(default_factory=UsageInfo)


class ModelInfo(BaseModel):
    """Information about a model."""

    id: str
    object: Literal["model"] = "model"
    created: int = Field(default_factory=lambda: int(time.time()))
    owned_by: str = "trio"


class ModelListResponse(BaseModel):
    """Response body for /v1/models endpoint."""

    object: Literal["list"] = "list"
    data: list[ModelInfo]


class Candidate(BaseModel):
    """A candidate response from a model with voting results."""

    model: str
    response: str
    accepted: int = 0
    preferred: int = 0


class VotingDetails(BaseModel):
    """Detailed voting information returned in X-Trio-Details header."""

    winner_index: int
    candidates: list[Candidate]
    aggregation_method: str = "acceptance_voting"
