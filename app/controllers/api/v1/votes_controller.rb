# typed: false

module Api::V1
  class VotesController < BaseController
    def create
      vote = api_helper.vote
      render json: vote
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      render json: { error: e.message }, status: 400
    end

    def update
      # The vote method handles both create and update (find_or_create pattern)
      vote = api_helper.vote
      render json: vote
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Vote not found' }, status: 404
    rescue StandardError => e
      render json: { error: e.message }, status: 400
    end
  end
end
