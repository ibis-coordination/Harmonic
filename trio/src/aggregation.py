"""Aggregation methods for selecting the best response from ensemble."""

import logging
import random
import re
from dataclasses import dataclass, field
from typing import Any

import httpx

from .config import Settings
from .llm import fetch_completion_simple

logger = logging.getLogger(__name__)


@dataclass
class AggregationResult:
    """Result of an aggregation method."""

    winner_index: int
    method: str
    # Per-response metadata (acceptance/preference counts, etc.)
    acceptance_counts: list[int] = field(default_factory=list)
    preference_counts: list[int] = field(default_factory=list)


async def aggregate_random(
    responses: list[tuple[str, str]],
    **kwargs: Any,
) -> AggregationResult:
    """Randomly select a response.

    Args:
        responses: List of (model_name, response_text) tuples

    Returns:
        AggregationResult with randomly selected winner
    """
    if not responses:
        return AggregationResult(winner_index=-1, method="random")

    winner_index = random.randint(0, len(responses) - 1)
    return AggregationResult(
        winner_index=winner_index,
        method="random",
        acceptance_counts=[0] * len(responses),
        preference_counts=[0] * len(responses),
    )


async def aggregate_acceptance(
    responses: list[tuple[str, str]],
    question: str,
    client: httpx.AsyncClient,
    settings: Settings,
    **kwargs: Any,
) -> AggregationResult:
    """Select best response using acceptance voting.

    Each model votes ACCEPTED/PREFERRED on all responses.
    Winner is ranked by acceptance count DESC, then preference count DESC.

    Args:
        responses: List of (model_name, response_text) tuples
        question: The original user question
        client: HTTP client for making LLM requests
        settings: Application settings

    Returns:
        AggregationResult with voting counts
    """
    # Import here to avoid circular import
    from .voting import run_acceptance_voting

    if not responses:
        return AggregationResult(winner_index=-1, method="acceptance_voting")

    acceptance_counts, preference_counts = await run_acceptance_voting(
        client, settings, question, responses
    )

    logger.debug(f"Acceptance counts: {acceptance_counts}")
    logger.debug(f"Preference counts: {preference_counts}")

    # Pick winner: acceptance count DESC, then preference count DESC
    winner_index = max(
        range(len(responses)),
        key=lambda i: (acceptance_counts[i], preference_counts[i]),
    )

    return AggregationResult(
        winner_index=winner_index,
        method="acceptance_voting",
        acceptance_counts=acceptance_counts,
        preference_counts=preference_counts,
    )


async def aggregate_judge(
    responses: list[tuple[str, str]],
    question: str,
    judge_model: str,
    client: httpx.AsyncClient,
    settings: Settings,
    **kwargs: Any,
) -> AggregationResult:
    """Select best response using a judge model.

    A separate judge model evaluates all responses and picks the best one.

    Args:
        responses: List of (model_name, response_text) tuples
        question: The original user question
        judge_model: Model name to use as judge
        client: HTTP client for making LLM requests
        settings: Application settings

    Returns:
        AggregationResult with judge's selection
    """
    if not responses:
        return AggregationResult(winner_index=-1, method="judge")

    # Build the judge prompt
    response_list = "\n\n---\n\n".join(
        f"Response {i + 1}:\n{resp}" for i, (_, resp) in enumerate(responses)
    )

    judge_prompt = f"""A user asked: "{question}"

Here are {len(responses)} candidate responses:

{response_list}

Which response best answers the user's question? Consider accuracy, completeness, and helpfulness.

Reply with just the number (1, 2, etc.) of the best response."""

    logger.debug(f"Asking judge model {judge_model} to evaluate {len(responses)} responses")

    result = await fetch_completion_simple(
        client,
        settings.trio_backend_url,
        judge_model,
        "You are evaluating responses. Pick the single best response. Reply with just a number.",
        judge_prompt,
    )

    if not result:
        logger.warning(f"Judge model {judge_model} returned empty response, falling back to first")
        return AggregationResult(
            winner_index=0,
            method="judge",
            acceptance_counts=[0] * len(responses),
            preference_counts=[0] * len(responses),
        )

    logger.debug(f"Judge response: {result}")

    # Extract the number from the response
    match = re.search(r"\d+", result)
    if match:
        winner_num = int(match.group()) - 1  # Convert to 0-indexed
        if 0 <= winner_num < len(responses):
            logger.debug(f"Judge selected response {winner_num + 1}")
            return AggregationResult(
                winner_index=winner_num,
                method="judge",
                acceptance_counts=[0] * len(responses),
                preference_counts=[0] * len(responses),
            )

    # Fallback if parsing fails
    logger.warning(f"Could not parse judge response '{result}', falling back to first")
    return AggregationResult(
        winner_index=0,
        method="judge",
        acceptance_counts=[0] * len(responses),
        preference_counts=[0] * len(responses),
    )


AGGREGATION_METHODS = ["acceptance_voting", "random", "judge"]


async def aggregate(
    method: str,
    responses: list[tuple[str, str]],
    question: str,
    client: httpx.AsyncClient,
    settings: Settings,
    judge_model: str | None = None,
) -> AggregationResult:
    """Dispatch to the appropriate aggregation method.

    Args:
        method: Aggregation method name ("acceptance_voting", "random", or "judge")
        responses: List of (model_name, response_text) tuples
        question: The original user question
        client: HTTP client for making LLM requests
        settings: Application settings
        judge_model: Model to use for judge aggregation (required if method is "judge")

    Returns:
        AggregationResult from the selected method

    Raises:
        ValueError: If method is unknown or judge_model missing for judge method
    """
    if method not in AGGREGATION_METHODS:
        raise ValueError(
            f"Unknown aggregation method '{method}'. "
            f"Valid methods: {AGGREGATION_METHODS}"
        )

    if method == "judge":
        if not judge_model:
            raise ValueError("judge_model is required when using 'judge' aggregation method")
        return await aggregate_judge(
            responses=responses,
            question=question,
            judge_model=judge_model,
            client=client,
            settings=settings,
        )
    elif method == "random":
        return await aggregate_random(responses=responses)
    else:  # acceptance_voting
        return await aggregate_acceptance(
            responses=responses,
            question=question,
            client=client,
            settings=settings,
        )
