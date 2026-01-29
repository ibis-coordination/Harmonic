# typed: false

module Api::V1
  class ApiTokensController < BaseController
    def index
      render json: current_user.api_tokens.map(&:api_json)
    end

    def show
      token = current_user.api_tokens.find_by(id: params[:id])
      return render json: { error: 'Token not found' }, status: 404 unless token
      render json: token.api_json(include: includes_param)
    end

    def create
      ActiveRecord::Base.transaction do
        token = ApiToken.create!(
          name: params[:name],
          user: current_user,
          expires_at: params[:expires_at] || 1.year.from_now,
          scopes: params[:scopes] || [],
        )
        render json: token.api_json
      rescue ActiveRecord::RecordInvalid => e
        # TODO - Detect specific validation errors and return helpful error messages
        render json: { error: 'There was an error creating the token. Please try again.' }, status: 400
      end
    end

    def update
      token = current_user.api_tokens.find_by(id: params[:id])
      return render json: { error: 'Token not found' }, status: 404 unless token
      updatable_attributes.each do |attribute|
        token[attribute] = params[attribute] if params.has_key?(attribute)
      end
      if token.changed?
        token.save!
      end
      render json: token.api_json
    end

    def destroy
      token = current_user.api_tokens.find_by(id: params[:id])
      return render json: { error: 'Token not found' }, status: 404 unless token
      token.delete!
      render json: { message: 'Token deleted' }
    end

    private

    def updatable_attributes
      [:name, :expires_at, :scopes, :active]
    end
  end
end
