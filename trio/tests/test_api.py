"""Tests for API endpoints."""

import json
import pytest
from unittest.mock import patch, AsyncMock

from fastapi.testclient import TestClient

from src.main import app
from src.models import VotingDetails, Candidate


@pytest.fixture
def client() -> TestClient:
    """Create a test client for the FastAPI app."""
    return TestClient(app)


class TestHealthEndpoint:
    """Tests for /health endpoint."""

    def test_health_returns_ok(self, client: TestClient) -> None:
        """Health endpoint returns status ok."""
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}


class TestModelsEndpoint:
    """Tests for /v1/models endpoint."""

    def test_lists_trio_model(self, client: TestClient) -> None:
        """Models endpoint lists trio as available model with version."""
        response = client.get("/v1/models")
        assert response.status_code == 200
        data = response.json()
        assert data["object"] == "list"
        assert len(data["data"]) == 1
        assert data["data"][0]["id"] == "trio-1.0"


class TestChatCompletionsEndpoint:
    """Tests for /v1/chat/completions endpoint."""

    def test_returns_openai_format(self, client: TestClient) -> None:
        """Response matches OpenAI chat completion format."""
        with patch("src.main.voting_completion") as mock_voting:
            mock_voting.return_value = (
                "Test response",
                VotingDetails(
                    winner_index=0,
                    candidates=[Candidate(model="test", response="Test response", accepted=1, preferred=1)],
                ),
            )

            response = client.post(
                "/v1/chat/completions",
                json={
                    "model": "trio",
                    "messages": [{"role": "user", "content": "Hello"}],
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["object"] == "chat.completion"
            assert data["model"] == "trio-1.0"
            assert len(data["choices"]) == 1
            assert data["choices"][0]["message"]["role"] == "assistant"
            assert data["choices"][0]["message"]["content"] == "Test response"
            assert data["choices"][0]["finish_reason"] == "stop"

    def test_includes_voting_details_header(self, client: TestClient) -> None:
        """X-Trio-Details header contains voting information."""
        with patch("src.main.voting_completion") as mock_voting:
            mock_voting.return_value = (
                "Winner",
                VotingDetails(
                    winner_index=0,
                    candidates=[
                        Candidate(model="model1", response="Winner", accepted=2, preferred=1),
                        Candidate(model="model2", response="Loser", accepted=1, preferred=0),
                    ],
                ),
            )

            response = client.post(
                "/v1/chat/completions",
                json={
                    "model": "trio",
                    "messages": [{"role": "user", "content": "Hello"}],
                },
            )

            assert "X-Trio-Details" in response.headers
            details = json.loads(response.headers["X-Trio-Details"])
            assert details["winner_index"] == 0
            assert len(details["candidates"]) == 2
            assert details["candidates"][0]["model"] == "model1"
            assert details["candidates"][0]["accepted"] == 2

    def test_accepts_trio_ensemble_parameter(self, client: TestClient) -> None:
        """Can specify models with custom prompts via trio_ensemble."""
        with patch("src.main.voting_completion") as mock_voting:
            mock_voting.return_value = (
                "Response",
                VotingDetails(winner_index=0, candidates=[]),
            )

            response = client.post(
                "/v1/chat/completions",
                json={
                    "model": "trio",
                    "messages": [{"role": "user", "content": "Hello"}],
                    "trio_ensemble": [
                        {"model": "model1", "system_prompt": "Be brief"},
                        {"model": "model2", "system_prompt": "Be detailed"},
                    ],
                },
            )

            assert response.status_code == 200
            call_args = mock_voting.call_args
            ensemble = call_args[0][3]
            assert len(ensemble) == 2
            assert ensemble[0].model == "model1"
            assert ensemble[0].system_prompt == "Be brief"
            assert ensemble[1].model == "model2"
            assert ensemble[1].system_prompt == "Be detailed"

    def test_validates_message_format(self, client: TestClient) -> None:
        """Rejects invalid message format."""
        response = client.post(
            "/v1/chat/completions",
            json={
                "model": "trio",
                "messages": [{"invalid": "format"}],
            },
        )

        assert response.status_code == 422  # Validation error

    def test_requires_messages(self, client: TestClient) -> None:
        """Messages field is required."""
        response = client.post(
            "/v1/chat/completions",
            json={"model": "trio"},
        )

        assert response.status_code == 422

    def test_rejects_ensemble_exceeding_max_size(self, client: TestClient) -> None:
        """Rejects ensemble with more than MAX_ENSEMBLE_SIZE models."""
        response = client.post(
            "/v1/chat/completions",
            json={
                "model": "trio",
                "messages": [{"role": "user", "content": "Hello"}],
                "trio_ensemble": [{"model": f"model{i}"} for i in range(10)],  # 10 > MAX_ENSEMBLE_SIZE (9)
            },
        )

        assert response.status_code == 400
        assert "exceeds maximum" in response.json()["detail"]
        assert "9" in response.json()["detail"]

    def test_accepts_ensemble_at_max_size(self, client: TestClient) -> None:
        """Accepts ensemble with exactly MAX_ENSEMBLE_SIZE models."""
        with patch("src.main.voting_completion") as mock_voting:
            mock_voting.return_value = (
                "Response",
                VotingDetails(winner_index=0, candidates=[]),
            )

            response = client.post(
                "/v1/chat/completions",
                json={
                    "model": "trio",
                    "messages": [{"role": "user", "content": "Hello"}],
                    "trio_ensemble": [{"model": f"model{i}"} for i in range(9)],  # Exactly 9
                },
            )

            assert response.status_code == 200

    def test_passthrough_mode_with_non_trio_model(self, client: TestClient) -> None:
        """Non-trio model name triggers pass-through mode."""
        with patch("src.main.voting_completion") as mock_voting:
            mock_voting.return_value = (
                "Direct response",
                VotingDetails(
                    winner_index=0,
                    candidates=[Candidate(model="mistral", response="Direct response", accepted=0, preferred=0)],
                ),
            )

            response = client.post(
                "/v1/chat/completions",
                json={
                    "model": "mistral",
                    "messages": [{"role": "user", "content": "Hello"}],
                },
            )

            assert response.status_code == 200
            data = response.json()
            # Response model should match the requested model
            assert data["model"] == "mistral"
            # Should have created single-model ensemble
            call_args = mock_voting.call_args
            ensemble = call_args[0][3]
            assert len(ensemble) == 1
            assert ensemble[0].model == "mistral"

    def test_passthrough_mode_ignores_trio_ensemble(self, client: TestClient) -> None:
        """Pass-through mode ignores trio_ensemble parameter."""
        with patch("src.main.voting_completion") as mock_voting:
            mock_voting.return_value = (
                "Direct response",
                VotingDetails(winner_index=0, candidates=[]),
            )

            response = client.post(
                "/v1/chat/completions",
                json={
                    "model": "llama3.2:3b",
                    "messages": [{"role": "user", "content": "Hello"}],
                    "trio_ensemble": [{"model": "ignored1"}, {"model": "ignored2"}],
                },
            )

            assert response.status_code == 200
            # Should use the model from request, not trio_ensemble
            call_args = mock_voting.call_args
            ensemble = call_args[0][3]
            assert len(ensemble) == 1
            assert ensemble[0].model == "llama3.2:3b"

    def test_trio_versioned_model_uses_ensemble(self, client: TestClient) -> None:
        """Model name 'trio-1.0' uses ensemble mode."""
        with patch("src.main.voting_completion") as mock_voting:
            mock_voting.return_value = (
                "Ensemble response",
                VotingDetails(winner_index=0, candidates=[]),
            )

            response = client.post(
                "/v1/chat/completions",
                json={
                    "model": "trio-1.0",
                    "messages": [{"role": "user", "content": "Hello"}],
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["model"] == "trio-1.0"
            # Should use default ensemble (multiple models)
            call_args = mock_voting.call_args
            ensemble = call_args[0][3]
            assert len(ensemble) > 1  # Default ensemble has multiple models
