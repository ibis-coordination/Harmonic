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

    # Exclude users involved in blocks (either direction) — single query
    block_ids = UserBlock
      .where("blocker_id = :uid OR blocked_id = :uid", uid: @current_user.id)
      .pluck(:blocker_id, :blocked_id)
      .flatten.uniq - [@current_user.id]
    collective_member_ids -= block_ids if block_ids.any?

    return render json: [] if collective_member_ids.empty?

    # Search tenant users by handle or display_name, limited to collective members
    tenant_users = TenantUser
      .where(tenant_id: @current_tenant.id)
      .where(user_id: collective_member_ids)
      .where(archived_at: nil)

    if query.present?
      sanitized_query = ActiveRecord::Base.sanitize_sql_like(query)
      tenant_users = tenant_users.where("LOWER(handle) LIKE :query OR LOWER(display_name) LIKE :query", query: "%#{sanitized_query}%")
    end

    tenant_users = tenant_users
      .includes(:user)
      .order(:handle)
      .limit(10)

    # Display active personas with their short mention tags (@cadence, …)
    # rather than their stored TenantUser handles (cadence-<collective
    # handle>). The mention parser resolves the tags back to this
    # collective's personas via their persona roles.
    persona_tags_by_user_id = {}
    @current_collective.persona_users.each do |agent|
      persona_tags_by_user_id[agent.id] = agent.system_role
    end

    results = tenant_users.map do |tu|
      display_handle = persona_tags_by_user_id[tu.user_id] || tu.handle
      {
        id: tu.user_id,
        handle: display_handle,
        display_name: tu.display_name,
        avatar_url: tu.user.image_url(variant: :icon),
      }
    end

    # If the query is a prefix of an active persona's tag (e.g., "", "c",
    # "cad") and that persona didn't surface via the substring search above
    # (e.g., the alphabetical top-10 with no query didn't include it),
    # inject it so persona-tag autocomplete always works.
    persona_tags_by_user_id.each do |user_id, tag|
      next unless query.empty? || tag.start_with?(query)
      next if results.any? { |r| r[:id] == user_id }

      persona_tu = TenantUser.where(tenant_id: @current_tenant.id, user_id: user_id).includes(:user).first
      next unless persona_tu

      results.unshift(
        id: persona_tu.user_id,
        handle: tag,
        display_name: persona_tu.display_name,
        avatar_url: persona_tu.user.image_url(variant: :icon),
      )
    end
    results = results.first(10)

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
