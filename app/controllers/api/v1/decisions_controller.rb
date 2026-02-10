# typed: false

module Api::V1
  class DecisionsController < BaseController
    def index
      index_not_supported_404
    end

    def create
      decision = api_helper.create_decision
      render json: decision
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: 400
    end

    def update
      decision = api_helper.update_decision_settings
      render json: decision
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Decision not found' }, status: 404
    rescue StandardError => e
      if e.message.include?('Unauthorized')
        render json: { error: 'Unauthorized' }, status: 403
      else
        render json: { error: e.message }, status: 400
      end
    end
  end
end
