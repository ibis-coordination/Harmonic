"""Acceptance voting logic for selecting the best response."""

import asyncio
import logging
import re

import httpx

from .config import Settings
from .llm import fetch_completion_simple
from .models import Candidate, ChatMessage, EnsembleMember, VotingDetails

DEFAULT_SYSTEM_PROMPT = "You are a helpful assistant."

logger = logging.getLogger(__name__)


async def generate_responses(
    client: httpx.AsyncClient,
    settings: Settings,
    messages: list[ChatMessage],
    ensemble: list[EnsembleMember],
    max_tokens: int,
    temperature: float,
) -> list[tuple[str, str | None]]:
    """Generate responses from all ensemble members in parallel.

    Args:
        client: HTTP client to use
        settings: Application settings
        messages: The conversation messages to complete
        ensemble: List of ensemble members with models and optional custom prompts
        max_tokens: Maximum tokens per response
        temperature: Sampling temperature

    Returns:
        List of (model_name, response_text) tuples
    """
    # Extract the default system prompt from messages, if present
    default_system = DEFAULT_SYSTEM_PROMPT
    if messages and messages[0].role == "system":
        default_system = messages[0].content

    # Extract the user message
    user_message = messages[-1].content if messages else ""

    tasks = []
    models = []
    for member in ensemble:
        # Use member's custom system_prompt if provided, otherwise fall back to default
        system_prompt = member.system_prompt if member.system_prompt else default_system
        task = fetch_completion_simple(
            client,
            settings.trio_backend_url,
            member.model,
            system_prompt,
            user_message,
            max_tokens,
            temperature,
        )
        tasks.append(task)
        models.append(member.model)

    # Run all tasks in parallel
    responses = await asyncio.gather(*tasks)

    results = []
    for model, response in zip(models, responses):
        results.append((model, response))
        if response:
            logger.debug(f"  {model}: {response[:80]}...")

    return results


async def get_voter_votes(
    client: httpx.AsyncClient,
    backend_url: str,
    voter_model: str,
    question: str,
    responses: list[str],
) -> tuple[list[int], list[int]]:
    """Get acceptance and preference votes from a model.

    Args:
        client: HTTP client to use
        backend_url: Backend LLM URL
        voter_model: Model name to use for voting
        question: The original question
        responses: List of candidate responses to evaluate

    Returns:
        Tuple of (accepted_indices, preferred_indices)
    """
    # Build the voting prompt
    response_list = "\n\n---\n\n".join(
        f"Response {i + 1}:\n{resp}" for i, resp in enumerate(responses)
    )

    voting_prompt = f"""A user asked: "{question}"

Here are {len(responses)} candidate responses:

{response_list}

Using acceptance voting, evaluate each response:
1. First, list ALL responses you find ACCEPTABLE (that adequately answer the question)
2. Then, from your acceptable responses, choose your PREFERRED response (the best one)

Reply in this exact format:
ACCEPTED: [comma-separated numbers, e.g., "1, 2, 3" or "1, 3"]
PREFERRED: [single number of your top choice from accepted responses]"""

    result = await fetch_completion_simple(
        client,
        backend_url,
        voter_model,
        "You are evaluating responses. Be thoughtful but decisive.",
        voting_prompt,
    )

    if not result:
        logger.debug(f"{voter_model} voting response: (empty)")
        return [], []

    logger.debug(f"{voter_model} voting response: {result[:200]}...")

    accepted: list[int] = []
    preferred: list[int] = []

    # Extract accepted numbers
    accepted_match = re.search(r"ACCEPTED:\s*([^\n]+)", result, re.IGNORECASE)
    if accepted_match:
        numbers = re.findall(r"\d+", accepted_match.group(1))
        accepted = [
            int(n) - 1 for n in numbers if 0 < int(n) <= len(responses)
        ]

    # Extract preferred number
    preferred_match = re.search(r"PREFERRED:\s*(\d+)", result, re.IGNORECASE)
    if preferred_match:
        pref_num = int(preferred_match.group(1)) - 1
        # Only count as preferred if it's also in accepted
        if 0 <= pref_num < len(responses) and pref_num in accepted:
            preferred = [pref_num]

    return accepted, preferred


async def run_acceptance_voting(
    client: httpx.AsyncClient,
    settings: Settings,
    question: str,
    responses_with_models: list[tuple[str, str]],
) -> tuple[list[int], list[int]]:
    """Run acceptance voting where each model votes on all responses.

    Args:
        client: HTTP client to use
        settings: Application settings
        question: The original question
        responses_with_models: List of (model_name, response_text) tuples

    Returns:
        Tuple of (acceptance_counts, preference_counts) per response
    """
    responses = [r for _, r in responses_with_models]
    n = len(responses)
    acceptance_counts = [0] * n
    preference_counts = [0] * n

    # Each model votes on all responses - run in parallel
    voting_tasks = []
    voting_models = []
    for model, _ in responses_with_models:
        task = get_voter_votes(
            client, settings.trio_backend_url, model, question, responses
        )
        voting_tasks.append(task)
        voting_models.append(model)

    # Run all voting tasks in parallel
    voting_results = await asyncio.gather(*voting_tasks)

    for model, (accepted, preferred) in zip(voting_models, voting_results):
        logger.debug(f"{model} accepted: {accepted}, preferred: {preferred}")

        for idx in accepted:
            if 0 <= idx < n:
                acceptance_counts[idx] += 1

        for idx in preferred:
            if 0 <= idx < n:
                preference_counts[idx] += 1

    return acceptance_counts, preference_counts


def pick_winner(
    responses_with_models: list[tuple[str, str]],
    acceptance_counts: list[int],
    preference_counts: list[int],
) -> int:
    """Pick the winning response based on acceptance and preference counts.

    Ranking: acceptance count DESC, then preference count DESC
    """
    if not responses_with_models:
        return -1

    return max(
        range(len(responses_with_models)),
        key=lambda i: (acceptance_counts[i], preference_counts[i]),
    )


async def voting_completion(
    client: httpx.AsyncClient,
    settings: Settings,
    messages: list[ChatMessage],
    ensemble: list[EnsembleMember],
    max_tokens: int = 500,
    temperature: float = 0.7,
    aggregation_method: str = "acceptance_voting",
    judge_model: str | None = None,
) -> tuple[str, VotingDetails]:
    """Run the full voting completion pipeline.

    Args:
        client: HTTP client to use
        settings: Application settings
        messages: Chat messages to complete
        ensemble: List of ensemble members with models and optional custom prompts
        max_tokens: Maximum tokens per response
        temperature: Sampling temperature
        aggregation_method: Method for selecting winner ("acceptance_voting", "random", "judge")
        judge_model: Model to use for judge aggregation (required if method is "judge")

    Returns:
        Tuple of (winning_response, voting_details)
    """
    # If only one model in ensemble, skip voting entirely - just pass through
    if len(ensemble) == 1:
        logger.debug("Single model in ensemble, skipping voting")
        member = ensemble[0]

        # Extract system prompt
        default_system = DEFAULT_SYSTEM_PROMPT
        if messages and messages[0].role == "system":
            default_system = messages[0].content
        system_prompt = member.system_prompt if member.system_prompt else default_system

        # Extract user message
        user_message = messages[-1].content if messages else ""

        response = await fetch_completion_simple(
            client,
            settings.trio_backend_url,
            member.model,
            system_prompt,
            user_message,
            max_tokens,
            temperature,
        )

        if not response:
            return "Sorry, I couldn't generate a response.", VotingDetails(
                winner_index=-1, candidates=[], aggregation_method="none"
            )

        return response, VotingDetails(
            winner_index=0,
            candidates=[Candidate(model=member.model, response=response, accepted=0, preferred=0)],
            aggregation_method="none",
        )

    # Phase 1: Generate responses from all models
    logger.debug(f"Generating responses from {len(ensemble)} models...")
    responses_with_models = await generate_responses(
        client, settings, messages, ensemble, max_tokens, temperature
    )

    # Filter out failed responses
    valid_responses = [(m, r) for m, r in responses_with_models if r]

    if not valid_responses:
        return "Sorry, I couldn't generate a response.", VotingDetails(
            winner_index=-1, candidates=[], aggregation_method="none"
        )

    logger.debug(f"Generated {len(valid_responses)} valid responses")

    # If only one valid response (due to failures), return it directly
    if len(valid_responses) == 1:
        model, response = valid_responses[0]
        return response, VotingDetails(
            winner_index=0,
            candidates=[Candidate(model=model, response=response, accepted=0, preferred=0)],
            aggregation_method="none",
        )

    # Extract the user's question from messages
    question = ""
    for msg in reversed(messages):
        if msg.role == "user":
            question = msg.content
            break

    # Import here to avoid circular import at module level
    from .aggregation import aggregate

    # Phase 2: Run aggregation to select winner
    logger.debug(f"Running {aggregation_method} aggregation...")
    result = await aggregate(
        method=aggregation_method,
        responses=valid_responses,
        question=question,
        client=client,
        settings=settings,
        judge_model=judge_model,
    )

    winner_index = result.winner_index
    winner_model, winner_response = valid_responses[winner_index]

    logger.debug(f"Winner (method={result.method}): {winner_response[:50]}...")

    # Build candidates list with vote counts
    candidates = [
        Candidate(
            model=model,
            response=response,
            accepted=result.acceptance_counts[i] if result.acceptance_counts else 0,
            preferred=result.preference_counts[i] if result.preference_counts else 0,
        )
        for i, (model, response) in enumerate(valid_responses)
    ]

    return winner_response, VotingDetails(
        winner_index=winner_index,
        candidates=candidates,
        aggregation_method=result.method,
    )
