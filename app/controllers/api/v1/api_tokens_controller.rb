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

    def create
      # Only humans can create API tokens. Agents that need a token must have
      # one minted for them by their parent human. Automated key rotation
      # would require a deliberate separate design.
      return render json: { error: 'Only human accounts can create API tokens' }, status: :forbidden unless current_user&.human?

      requested_scopes = params[:scopes] || []
      ungranted = scopes_not_grantable_by_current_token(requested_scopes)
      if ungranted.any?
        return render json: { error: "Cannot grant scope(s) the creating token does not have: #{ungranted.join(', ')}" }, status: :forbidden
      end

      ActiveRecord::Base.transaction do
        token = ApiToken.create!(
          name: params[:name],
          user: current_user,
          expires_at: params[:expires_at] || 1.year.from_now,
          scopes: requested_scopes,
        )
        render json: token.api_json
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: safe_validation_message(e.record) }, status: 400
      end
    end

    def update
      # Never allow updating internal tokens
      token = current_user.api_tokens.external.find_by(id: params[:id])
      return render json: { error: 'Token not found' }, status: 404 unless token

      # Tokens are immutable except for `name`. To change a token's scopes or
      # expiration, create a new token and delete the old one. This prevents
      # post-creation privilege or lifetime escalation.
      immutable_changes = (params.keys.map(&:to_sym) & IMMUTABLE_ATTRIBUTES)
      if immutable_changes.any?
        return render json: { error: "Tokens are immutable except for `name`. To change #{immutable_changes.join(', ')}, create a new token and delete this one." }, status: :bad_request
      end

      token.name = params[:name] if params.has_key?(:name)
      token.save! if token.changed?
      render json: token.api_json
    end

    def destroy
      # Never allow deleting internal tokens
      token = current_user.api_tokens.external.find_by(id: params[:id])
      return render json: { error: 'Token not found' }, status: 404 unless token
      token.delete!
      render json: { message: 'Token deleted' }
    end

    # Attributes that cannot be changed after creation. Listed explicitly so a
    # request that tries to change them returns a clear 400 instead of being
    # silently ignored.
    IMMUTABLE_ATTRIBUTES = %i[expires_at scopes active internal context context_id context_type].freeze

    private

    # Prevent privilege escalation: a token may only mint child tokens with
    # scopes it is itself authorized for. Returns the subset of requested
    # scopes that the current token cannot grant.
    def scopes_not_grantable_by_current_token(requested_scopes)
      current_scopes = current_token&.scopes || []
      requested_scopes.reject { |scope| scope_grantable?(scope, current_scopes) }
    end

    def scope_grantable?(scope, current_scopes)
      return true if current_scopes.include?(scope)

      action = scope.to_s.split(":").first
      current_scopes.include?("#{action}:all")
    end

    # Only surface validation errors on user-controllable fields. Errors on
    # internal attributes (`internal`, `context`, `token_hash`) describe
    # implementation details and shouldn't leak through the public API.
    SAFE_ERROR_ATTRIBUTES = %i[base name scopes expires_at].freeze

    def safe_validation_message(record)
      safe = record.errors.filter_map do |error|
        next unless SAFE_ERROR_ATTRIBUTES.include?(error.attribute)
        error.attribute == :base ? error.message : error.full_message
      end
      safe.any? ? safe.join(", ") : "There was an error creating the token. Please try again."
    end
  end
end
