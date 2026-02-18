# typed: false

class AutocompleteController < ApplicationController
  before_action :require_user

  # GET /autocomplete/users?q=search_term
  # Returns JSON list of users matching the search query for @mention autocomplete
  # Scoped to members of the current collective
  # If query is blank, returns 10 collective members sorted alphabetically by handle
  def users
    query = params[:q].to_s.strip.downcase
    return render json: [] if @current_collective.blank?

    # Get user IDs who are members of the current collective (excluding current user)
    collective_member_ids = CollectiveMember
      .where(tenant_id: @current_tenant.id, collective_id: @current_collective.id, archived_at: nil)
      .where.not(user_id: @current_user.id)
      .pluck(:user_id)

    return render json: [] if collective_member_ids.empty?

    # Search tenant users by handle or display_name, limited to collective members
    tenant_users = TenantUser
      .where(tenant_id: @current_tenant.id)
      .where(user_id: collective_member_ids)
      .where(archived_at: nil)

    if query.present?
      tenant_users = tenant_users.where("LOWER(handle) LIKE :query OR LOWER(display_name) LIKE :query", query: "%#{query}%")
    end

    tenant_users = tenant_users
      .includes(:user)
      .order(:handle)
      .limit(10)

    results = tenant_users.map do |tu|
      {
        id: tu.user_id,
        handle: tu.handle,
        display_name: tu.display_name,
        avatar_url: tu.user.image_url,
      }
    end

    render json: results
  end

  private

  def require_user
    return if current_user

    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  # Override to avoid trying to find a non-existent Autocomplete model
  def current_resource_model
    nil
  end
end
