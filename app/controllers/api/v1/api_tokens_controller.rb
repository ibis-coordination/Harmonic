# typed: false

module Api::V1
  class ApiTokensController < BaseController
    def index
      # Never show internal tokens - they are for system use only
      render json: current_user.api_tokens.external.map(&:api_json)
    end

    def show
      # Never show internal tokens
      token = current_user.api_tokens.external.find_by(id: params[:id])
      return render json: { error: 'Token not found' }, status: 404 unless token

      render json: token.api_json(include: includes_param)
    end
  end
end
