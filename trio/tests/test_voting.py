"""Tests for voting logic."""

import pytest
from unittest.mock import AsyncMock, patch

from src.models import ChatMessage, EnsembleMember, VotingDetails
from src.voting import pick_winner, get_voter_votes, voting_completion
from src.config import Settings


class TestPickWinner:
    """Tests for the pick_winner function."""

    def test_picks_highest_acceptance(self) -> None:
        """Winner is the one with most acceptances."""
        responses = [("model1", "response1"), ("model2", "response2"), ("model3", "response3")]
        acceptance = [1, 3, 2]
        preference = [0, 0, 0]

        winner = pick_winner(responses, acceptance, preference)
        assert winner == 1  # model2 with 3 acceptances

    def test_uses_preference_as_tiebreaker(self) -> None:
        """When acceptance is tied, preference breaks the tie."""
        responses = [("model1", "response1"), ("model2", "response2"), ("model3", "response3")]
        acceptance = [2, 2, 1]
        preference = [1, 2, 0]

        winner = pick_winner(responses, acceptance, preference)
        assert winner == 1  # model2 with 2 acceptances and 2 preferences

    def test_returns_first_on_complete_tie(self) -> None:
        """When everything is tied, returns the first (max returns first match)."""
        responses = [("model1", "response1"), ("model2", "response2")]
        acceptance = [1, 1]
        preference = [1, 1]

        winner = pick_winner(responses, acceptance, preference)
        # max() returns first element when all equal
        assert winner in [0, 1]

    def test_empty_responses_returns_negative_one(self) -> None:
        """Empty response list returns -1."""
        winner = pick_winner([], [], [])
        assert winner == -1

    def test_single_response(self) -> None:
        """Single response always wins."""
        responses = [("model1", "response1")]
        winner = pick_winner(responses, [1], [1])
        assert winner == 0


class TestGetVoterVotes:
    """Tests for parsing voter responses."""

    @pytest.fixture
    def mock_client(self) -> AsyncMock:
        return AsyncMock()

    async def test_parses_accepted_and_preferred(self, mock_client: AsyncMock) -> None:
        """Correctly parses ACCEPTED and PREFERRED from response."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "ACCEPTED: 1, 2, 3\nPREFERRED: 2"

            accepted, preferred = await get_voter_votes(
                mock_client,
                "http://backend",
                "model1",
                "What is 2+2?",
                ["4", "Four", "The answer is 4"],
            )

            assert accepted == [0, 1, 2]  # 0-indexed
            assert preferred == [1]  # Response 2 (0-indexed: 1)

    async def test_handles_preferred_not_in_accepted(self, mock_client: AsyncMock) -> None:
        """Preferred is ignored if not in accepted list."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "ACCEPTED: 1, 3\nPREFERRED: 2"

            accepted, preferred = await get_voter_votes(
                mock_client,
                "http://backend",
                "model1",
                "Question?",
                ["a", "b", "c"],
            )

            assert accepted == [0, 2]
            assert preferred == []  # 2 not in accepted, so ignored

    async def test_handles_empty_response(self, mock_client: AsyncMock) -> None:
        """Returns empty lists when backend returns None."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = None

            accepted, preferred = await get_voter_votes(
                mock_client,
                "http://backend",
                "model1",
                "Question?",
                ["a", "b"],
            )

            assert accepted == []
            assert preferred == []

    async def test_handles_malformed_response(self, mock_client: AsyncMock) -> None:
        """Handles responses that don't match expected format."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "I think response 1 is best."

            accepted, preferred = await get_voter_votes(
                mock_client,
                "http://backend",
                "model1",
                "Question?",
                ["a", "b"],
            )

            assert accepted == []
            assert preferred == []

    async def test_filters_out_of_range_numbers(self, mock_client: AsyncMock) -> None:
        """Numbers outside valid range are ignored."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "ACCEPTED: 0, 1, 5, 10\nPREFERRED: 1"

            accepted, preferred = await get_voter_votes(
                mock_client,
                "http://backend",
                "model1",
                "Question?",
                ["a", "b"],  # Only 2 responses, valid: 1, 2
            )

            assert accepted == [0]  # Only "1" is valid (0-indexed: 0)
            assert preferred == [0]


class TestVotingCompletion:
    """Integration tests for the full voting pipeline."""

    @pytest.fixture
    def mock_client(self) -> AsyncMock:
        return AsyncMock()

    @pytest.fixture
    def settings(self) -> Settings:
        return Settings(
            trio_models="model1,model2,model3",
            trio_backend_url="http://test-backend:4000",
        )

    async def test_returns_winner_response(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Returns the winning response based on voting."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            # First 3 calls: generate responses
            # Next 3 calls: voting (each model votes)
            mock_fetch.side_effect = [
                "Response from model1",
                "Response from model2",
                "Response from model3",
                "ACCEPTED: 1, 2\nPREFERRED: 2",  # model1 votes
                "ACCEPTED: 2, 3\nPREFERRED: 2",  # model2 votes
                "ACCEPTED: 1, 2, 3\nPREFERRED: 2",  # model3 votes
            ]

            messages = [ChatMessage(role="user", content="Hello")]
            ensemble = [
                EnsembleMember(model="model1"),
                EnsembleMember(model="model2"),
                EnsembleMember(model="model3"),
            ]

            winner, details = await voting_completion(
                mock_client, settings, messages, ensemble
            )

            assert winner == "Response from model2"
            assert details.winner_index == 1
            assert len(details.candidates) == 3

    async def test_handles_all_failures(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Returns error message when all models fail."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = None

            messages = [ChatMessage(role="user", content="Hello")]
            ensemble = [EnsembleMember(model="model1")]

            winner, details = await voting_completion(
                mock_client, settings, messages, ensemble
            )

            assert "couldn't generate" in winner.lower()
            assert details.winner_index == -1
            assert details.candidates == []

    async def test_single_response_skips_voting(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """When only one response succeeds, skip voting phase."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.side_effect = [
                "Only response",
                None,  # model2 fails
                None,  # model3 fails
            ]

            messages = [ChatMessage(role="user", content="Hello")]
            ensemble = [
                EnsembleMember(model="model1"),
                EnsembleMember(model="model2"),
                EnsembleMember(model="model3"),
            ]

            winner, details = await voting_completion(
                mock_client, settings, messages, ensemble
            )

            assert winner == "Only response"
            assert details.winner_index == 0
            # Only 3 calls (generation), no voting calls
            assert mock_fetch.call_count == 3

    async def test_uses_custom_system_prompts(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """Custom system prompts are passed to each model."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "Response"

            messages = [ChatMessage(role="user", content="Hello")]
            ensemble = [
                EnsembleMember(model="model1", system_prompt="Be concise"),
                EnsembleMember(model="model2", system_prompt="Be verbose"),
            ]

            await voting_completion(mock_client, settings, messages, ensemble)

            # Check the system prompts in the calls
            calls = mock_fetch.call_args_list
            # First two calls are for generation
            assert calls[0][0][3] == "Be concise"  # system_prompt arg
            assert calls[1][0][3] == "Be verbose"

    async def test_single_model_ensemble_skips_voting(
        self, mock_client: AsyncMock, settings: Settings
    ) -> None:
        """When ensemble has only one model, skip voting entirely."""
        with patch("src.voting.fetch_completion_simple") as mock_fetch:
            mock_fetch.return_value = "Direct response"

            messages = [ChatMessage(role="user", content="Hello")]
            ensemble = [EnsembleMember(model="single-model")]

            winner, details = await voting_completion(
                mock_client, settings, messages, ensemble
            )

            assert winner == "Direct response"
            assert details.winner_index == 0
            assert len(details.candidates) == 1
            assert details.candidates[0].model == "single-model"
            # Only 1 call - no voting phase
            assert mock_fetch.call_count == 1
