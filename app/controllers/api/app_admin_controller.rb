# typed: false

# Base controller for the App Admin API (/api/app_admin/*).
#
# This API is used by the Harmonic Admin App (private repo) to manage tenants
# across the entire application. It handles billing integration, customer support,
# and operational tasks that don't belong in the open-source product.
#
# Authorization requires BOTH:
# 1. Token flag: api_token.app_admin? must be true
# 2. User role: api_token.user.app_admin? must be true
#
# This redundant check is a security feature. Both are set via Rails console only.
#
class Api::AppAdminController < ApplicationController
  skip_before_action :current_superagent, :current_tenant, :current_user,
                     :current_resource, :current_representation_session,
                     :current_heartbeat, :load_unread_notification_count

  before_action :authenticate_app_admin!

  private

  def authenticate_app_admin!
    token = extract_token
    return render_unauthorized("Missing authorization token") unless token

    # Use hash-based lookup (Tenant.current_id is nil because we skip current_tenant,
    # so the default scope returns all records - no unscoped needed)
    token_hash = ApiToken.hash_token(token)
    @current_token = ApiToken.find_by(token_hash: token_hash, deleted_at: nil)
    return render_unauthorized("Invalid token") unless @current_token

    if @current_token.expired?
      return render_unauthorized("Token expired")
    end

    unless @current_token.app_admin?
      return render_forbidden("Token does not have app_admin access")
    end

    @current_user = @current_token.user
    unless @current_user&.app_admin?
      return render_forbidden("User does not have app_admin role")
    end

    @current_token.token_used!
  end

  def extract_token
    auth_header = request.headers["Authorization"]
    return nil unless auth_header

    prefix, token = auth_header.split(" ")
    return nil unless prefix == "Bearer"

    token
  end

  def render_unauthorized(message)
    render json: { error: message }, status: :unauthorized
  end

  def render_forbidden(message)
    render json: { error: message }, status: :forbidden
  end

  def render_not_found(message = "Not found")
    render json: { error: message }, status: :not_found
  end
end
