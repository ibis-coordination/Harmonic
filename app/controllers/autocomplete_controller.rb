# typed: false

class AutocompleteController < ApplicationController
  before_action :require_user

  # GET /autocomplete/users?q=search_term
  # Returns JSON list of users matching the search query for @mention autocomplete
  # Scoped to members of the current collective
  # If query is blank, returns 10 collective members sorted alphabetically by handle
  #
  # Group tags (@everyone and the role tags @admins/@representatives/…) are not
  # users, so the member search below never surfaces them; they're injected
  # separately so typing "@rep" discovers "@representatives" the same way it
  # finds a person (#465).
  def users
    query = params[:q].to_s.strip.downcase
    return render json: [] if @current_collective.blank?

    # Group tags surface regardless of the member-search early-returns below
    # (which fire when the collective has no other/searchable members), so a
    # role tag is still discoverable in a collective where you're the only one
    # composing.
    tag_results = group_tag_suggestions(query)

    render json: (tag_results + member_suggestions(query)).first(10)
  end

  private

  # The user half of the autocomplete: collective members matching `query`,
  # plus the @trio magic handle. Returns [] (not a rendered response) so #users
  # can merge it with the group-tag suggestions.
  def member_suggestions(query)
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

    return [] if collective_member_ids.empty?

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

    # Display the collective's trio with the magic handle "trio" rather
    # than its stored TenantUser handle (which is hex-suffixed for non-main
    # collectives to avoid the tenant-wide handle collision). The mention
    # parser resolves "@trio" back to this collective's trio via the
    # collective.trio_user link.
    trio_user_id = @current_collective.trio_user_id

    results = tenant_users.map do |tu|
      display_handle = tu.user_id == trio_user_id ? MentionParser::TRIO_HANDLE : tu.handle
      {
        id: tu.user_id,
        handle: display_handle,
        display_name: tu.display_name,
        avatar_url: tu.user.image_url(variant: :icon),
      }
    end

    # If the query is a prefix of "trio" (e.g., "", "t", "tr", "tri", "trio")
    # and chariot's trio didn't surface via the substring search above
    # (e.g., the alphabetical top-10 with no query didn't include it),
    # inject it so "@trio" autocomplete always works.
    query_is_trio_prefix = query.empty? || MentionParser::TRIO_HANDLE.start_with?(query)
    if trio_user_id && query_is_trio_prefix && results.none? { |r| r[:id] == trio_user_id }
      trio_tu = TenantUser.where(tenant_id: @current_tenant.id, user_id: trio_user_id).includes(:user).first
      if trio_tu
        results.unshift(
          id: trio_tu.user_id,
          handle: MentionParser::TRIO_HANDLE,
          display_name: trio_tu.display_name,
          avatar_url: trio_tu.user.image_url(variant: :icon),
        )
        results = results.first(10)
      end
    end

    results
  end

  # Group-tag suggestions matching `query`: the role tags (@admins,
  # @representatives, @summarizers, …) and @everyone. A role tag is offered only
  # when someone in the collective actually holds that role, so we never suggest
  # a mention that would expand to nobody. @everyone is offered only to admins,
  # mirroring its admin-only delivery gate (MentionParser.resolve_collective_local)
  # so a non-admin isn't shown a tag they can't fan out. Handles come straight
  # from ReservedHandles, so a new/custom role's tag surfaces here with no change.
  def group_tag_suggestions(query)
    suggestions = ReservedHandles.role_tags.filter_map do |tag, role|
      next unless tag_matches?(tag, query)
      next if @current_collective.users_with_role(role).empty?

      group_tag_result(tag)
    end

    everyone = ReservedHandles::EVERYONE
    if tag_matches?(everyone, query) && @current_collective.admin?(@current_user)
      suggestions << group_tag_result(everyone)
    end

    suggestions
  end

  # A tag matches when the typed query is a prefix of it (so "@rep" offers
  # "@representatives"), or when nothing's been typed yet.
  def tag_matches?(tag, query)
    query.empty? || tag.start_with?(query)
  end

  def group_tag_result(tag)
    {
      id: "group:#{tag}",
      handle: tag,
      display_name: tag.titleize,
      avatar_url: nil,
      group: true,
    }
  end

  def require_user
    return if current_user

    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  # Override to avoid trying to find a non-existent Autocomplete model
  def current_resource_model
    nil
  end
end
