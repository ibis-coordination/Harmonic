"""LLM backend client for making completion requests."""

import logging

import httpx

from .models import ChatMessage

logger = logging.getLogger(__name__)


async def fetch_completion(
    client: httpx.AsyncClient,
    backend_url: str,
    model: str,
    messages: list[ChatMessage],
    max_tokens: int = 500,
    temperature: float = 0.7,
) -> str | None:
    """Fetch a completion from the backend LLM.

    Args:
        client: HTTP client to use for the request
        backend_url: Base URL of the LLM backend (e.g., http://litellm:4000)
        model: Model name to use
        messages: List of chat messages
        max_tokens: Maximum tokens to generate
        temperature: Sampling temperature

    Returns:
        The completion text, or None if the request failed
    """
    try:
        response = await client.post(
            f"{backend_url}/v1/chat/completions",
            json={
                "model": model,
                "messages": [{"role": m.role, "content": m.content} for m in messages],
                "max_tokens": max_tokens,
                "temperature": temperature,
            },
        )
        response.raise_for_status()

        data = response.json()
        content = data.get("choices", [{}])[0].get("message", {}).get("content")
        return content.strip() if content else None

    except httpx.HTTPStatusError as e:
        logger.warning(f"HTTP error from model {model}: {e.response.status_code}")
        return None
    except httpx.RequestError as e:
        logger.warning(f"Request error for model {model}: {e}")
        return None
    except (KeyError, IndexError, TypeError) as e:
        logger.warning(f"Parse error for model {model}: {e}")
        return None


async def fetch_completion_simple(
    client: httpx.AsyncClient,
    backend_url: str,
    model: str,
    system_prompt: str,
    user_message: str,
    max_tokens: int = 500,
    temperature: float = 0.7,
) -> str | None:
    """Convenience wrapper for simple system + user message completions."""
    messages = [
        ChatMessage(role="system", content=system_prompt),
        ChatMessage(role="user", content=user_message),
    ]
    return await fetch_completion(
        client, backend_url, model, messages, max_tokens, temperature
    )
