# typed: false

module Api::V1
  class CommitmentsController < BaseController
    def index
      index_not_supported_404
    end

    def create
      commitment = api_helper.create_commitment
      render json: commitment.api_json
    rescue ActiveRecord::RecordInvalid, StandardError => e
      render json: { error: e.message }, status: 400
    end

    def update
      commitment = api_helper.update_commitment_settings
      render json: commitment.api_json
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Commitment not found' }, status: 404
    rescue StandardError => e
      if e.message.include?('Unauthorized')
        render json: { error: 'Unauthorized' }, status: 403
      else
        render json: { error: e.message }, status: 400
      end
    end

    def join
      participant = api_helper.join_commitment
      render json: participant.api_json
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Commitment not found' }, status: 404
    rescue StandardError => e
      if e.message.include?('closed')
        render json: { error: 'This commitment is closed.' }, status: 400
      else
        render json: { error: e.message }, status: 400
      end
    end
  end
end
