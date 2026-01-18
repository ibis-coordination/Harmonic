"""Tests for aggregation methods."""

import pytest
from unittest.mock import AsyncMock, patch

from src.aggregation import (
    aggregate,
    aggregate_random,
    aggregate_acceptance,
    aggregate_judge,
    AggregationResult,
    AGGREGATION_METHODS,
)
from src.config import Settings


class TestAggregateRandom:
    """Tests for random aggregation."""

    async def test_returns_valid_index(self) -> None:
        """Random selection returns a valid index."""
        responses = [("model1", "resp1"), ("model2", "resp2"), ("model3", "resp3")]

        result = await aggregate_random(responses)

        assert result.method == "random"
        assert 0 <= result.winner_index < len(responses)

    async def test_empty_responses_returns_negative_one(self) -> None:
        """Empty response list returns -1."""
        result = await aggregate_random([])

        assert result.winner_index == -1
        assert result.method == "random"

    async def test_single_response(self) -> None:
        """Single response always returns index 0."""
        responses = [("model1", "only response")]

        result = await aggregate_random(responses)

        assert result.winner_index == 0


class TestAggregateAcceptance:
    """Tests for acceptance_voting voting aggregation."""

    @pytest.fixture
    def mock_client(self) -> AsyncMock:
        return AsyncMock()

    @pytest.fixture
    def settings(self) -> Settings:
        return Settings(
            trio_models="model1,model2",
            trio_backend_url="http://test-backend:4000",
        )

    async def test_uses_voting_counts(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Acceptance aggregation uses run_acceptance_voting results."""
        with patch("src.voting.run_acceptance_voting") as mock_voting:
            mock_voting.return_value = ([2, 3, 1], [1, 2, 0])

            responses = [("m1", "r1"), ("m2", "r2"), ("m3", "r3")]
            result = await aggregate_acceptance(
                responses, "question?", mock_client, settings
            )

            assert result.method == "acceptance_voting"
            assert result.winner_index == 1  # model2 has most acceptances
            assert result.acceptance_counts == [2, 3, 1]
            assert result.preference_counts == [1, 2, 0]

    async def test_empty_responses(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Empty responses returns -1."""
        result = await aggregate_acceptance([], "question?", mock_client, settings)

        assert result.winner_index == -1


class TestAggregateJudge:
    """Tests for judge model aggregation."""

    @pytest.fixture
    def mock_client(self) -> AsyncMock:
        return AsyncMock()

    @pytest.fixture
    def settings(self) -> Settings:
        return Settings(
            trio_models="model1,model2",
            trio_backend_url="http://test-backend:4000",
        )

    async def test_parses_judge_selection(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Judge method correctly parses model's selection."""
        with patch("src.aggregation.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "2"

            responses = [("m1", "r1"), ("m2", "r2"), ("m3", "r3")]
            result = await aggregate_judge(
                responses, "question?", "judge-model", mock_client, settings
            )

            assert result.method == "judge"
            assert result.winner_index == 1  # Response 2 (0-indexed: 1)

    async def test_handles_verbose_judge_response(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Extracts number from verbose judge response."""
        with patch("src.aggregation.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "Response 3 is the best because it's clear."

            responses = [("m1", "r1"), ("m2", "r2"), ("m3", "r3")]
            result = await aggregate_judge(
                responses, "question?", "judge-model", mock_client, settings
            )

            assert result.winner_index == 2  # First number found: 3 (0-indexed: 2)

    async def test_fallback_on_empty_response(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Falls back to first response when judge returns nothing."""
        with patch("src.aggregation.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = None

            responses = [("m1", "r1"), ("m2", "r2")]
            result = await aggregate_judge(
                responses, "question?", "judge-model", mock_client, settings
            )

            assert result.winner_index == 0

    async def test_fallback_on_invalid_number(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Falls back when judge returns invalid number."""
        with patch("src.aggregation.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "99"  # Out of range

            responses = [("m1", "r1"), ("m2", "r2")]
            result = await aggregate_judge(
                responses, "question?", "judge-model", mock_client, settings
            )

            assert result.winner_index == 0

    async def test_empty_responses(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Empty responses returns -1."""
        result = await aggregate_judge(
            [], "question?", "judge-model", mock_client, settings
        )

        assert result.winner_index == -1


class TestAggregateDispatcher:
    """Tests for the aggregate() dispatcher function."""

    @pytest.fixture
    def mock_client(self) -> AsyncMock:
        return AsyncMock()

    @pytest.fixture
    def settings(self) -> Settings:
        return Settings(
            trio_models="model1,model2",
            trio_backend_url="http://test-backend:4000",
        )

    async def test_dispatches_to_random(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Dispatches to random aggregation."""
        responses = [("m1", "r1"), ("m2", "r2")]
        result = await aggregate(
            "random", responses, "question?", mock_client, settings
        )

        assert result.method == "random"

    async def test_dispatches_to_acceptance_voting(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Dispatches to acceptance_voting aggregation."""
        with patch("src.voting.run_acceptance_voting") as mock_voting:
            mock_voting.return_value = ([1, 2], [0, 1])

            responses = [("m1", "r1"), ("m2", "r2")]
            result = await aggregate(
                "acceptance_voting", responses, "question?", mock_client, settings
            )

            assert result.method == "acceptance_voting"

    async def test_dispatches_to_judge(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Dispatches to judge aggregation."""
        with patch("src.aggregation.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "1"

            responses = [("m1", "r1"), ("m2", "r2")]
            result = await aggregate(
                "judge", responses, "question?", mock_client, settings, "judge-model"
            )

            assert result.method == "judge"

    async def test_raises_on_unknown_method(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Raises ValueError for unknown aggregation method."""
        with pytest.raises(ValueError, match="Unknown aggregation method"):
            await aggregate(
                "nonexistent", [], "question?", mock_client, settings
            )

    async def test_raises_on_judge_without_model(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Raises ValueError when judge method lacks judge_model."""
        with pytest.raises(ValueError, match="judge_model is required"):
            await aggregate(
                "judge", [], "question?", mock_client, settings, None
            )


class TestAggregationMethodRegistry:
    """Tests for the AGGREGATION_METHODS registry."""

    def test_all_methods_registered(self) -> None:
        """All expected methods are in the registry."""
        assert "acceptance_voting" in AGGREGATION_METHODS
        assert "random" in AGGREGATION_METHODS
        assert "judge" in AGGREGATION_METHODS

    def test_expected_method_count(self) -> None:
        """Registry has expected number of methods."""
        assert len(AGGREGATION_METHODS) == 3
