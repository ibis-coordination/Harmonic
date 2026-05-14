# typed: false

module Api::V1
  class VotesController < BaseController
    # Read-only API: index and show inherited from BaseController.
    # To cast a vote, use the markdown UI action: POST /d/:id/actions/vote.
  end
end
