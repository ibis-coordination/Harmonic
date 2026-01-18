"""Configuration settings loaded from environment variables."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings.

    All settings can be overridden via environment variables.
    """

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # Comma-separated list of model names to use for voting
    # These should match model_name entries in litellm_config.yaml
    trio_models: str = "default,llama3.2-3b,mistral"

    # Backend LLM URL (LiteLLM proxy or direct Ollama)
    trio_backend_url: str = "http://litellm:4000"

    # Service port
    trio_port: int = 8000

    # Timeout for each model request (seconds)
    trio_timeout: int = 120

    # Aggregation method: "acceptance_voting", "random", or "judge"
    trio_aggregation_method: str = "acceptance_voting"

    # Model to use for judge aggregation (required if method is "judge")
    trio_judge_model: str | None = None

    @property
    def models(self) -> list[str]:
        """Parse comma-separated model string into list."""
        return [m.strip() for m in self.trio_models.split(",") if m.strip()]


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()
