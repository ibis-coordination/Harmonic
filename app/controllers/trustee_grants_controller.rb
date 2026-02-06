# typed: false

# TrusteeGrantsController manages user-to-user trustee grants.
# This allows users to grant other users (or agents) authority to act on their behalf.
#
# Key concepts:
# - granting_user: The user who grants authority (the "principal")
# - trusted_user: The user who receives authority (the "trustee")
# - trustee_user: A synthetic "trustee" user created to represent the grant relationship
#
# Routes are under /u/:handle/settings/trustee-grants
class TrusteeGrantsController < ApplicationController
  before_action :require_login
  before_action :set_target_user
  before_action :set_sidebar_mode, only: [:index, :new, :show]
  before_action :set_grant, only: [
    :show, :actions_index_show,
    :describe_accept, :execute_accept,
    :describe_decline, :execute_decline,
    :describe_revoke, :execute_revoke,
  ]

  # Override to avoid model lookup issues
  def current_resource_model
    nil
  end

  # GET /u/:handle/settings/trustee-grants
  def index
    @page_title = "Trustee Grants for #{@target_user.display_name || @target_user.handle}"

    # Grants I've given to others (I am granting_user)
    @granted = TrusteeGrant.unscoped
      .where(granting_user: @target_user, tenant: @current_tenant)
      .includes(:trusted_user, :trustee_user)

    # Grants I've received from others (I am trusted_user)
    @received = TrusteeGrant.unscoped
      .where(trusted_user: @target_user, tenant: @current_tenant)
      .includes(:granting_user, :trustee_user)

    # Pending requests I need to respond to
    @pending_requests = @received.pending
  end

  # GET /u/:handle/settings/trustee-grants/:grant_id
  def show
    @page_title = "Trustee Grant: #{@grant.display_name}"
  end

  # GET /u/:handle/settings/trustee-grants/new
  def new
    @page_title = "Create Trustee Grant"
    @grant = TrusteeGrant.new
    @available_users = available_users_for_grant
    @available_studios = @target_user.superagents
    @capabilities = TrusteeGrant::CAPABILITIES
  end

  # =========================================================================
  # ACTIONS INDEX METHODS
  # =========================================================================

  def actions_index
    render_actions_index(ActionsHelper.actions_for_route("/u/:handle/settings/trustee-grants"))
  end

  def actions_index_new
    render_actions_index(ActionsHelper.actions_for_route("/u/:handle/settings/trustee-grants/new"))
  end

  def actions_index_show
    # Build dynamic actions based on grant state
    actions = []

    if @grant.pending? && @grant.trusted_user == @target_user
      actions << {
        name: "accept_trustee_grant",
        params_string: "()",
        description: "Accept this trustee grant request",
      }
      actions << {
        name: "decline_trustee_grant",
        params_string: "()",
        description: "Decline this trustee grant request",
      }
    end

    if @grant.granting_user == @target_user && !@grant.revoked? && !@grant.declined?
      actions << {
        name: "revoke_trustee_grant",
        params_string: "()",
        description: "Revoke this trustee grant",
      }
    end

    render_actions_index({ actions: actions })
  end

  # =========================================================================
  # CREATE TRUSTEE GRANT
  # =========================================================================

  def describe_create
    render_action_description(ActionsHelper.action_description("create_trustee_grant", resource: nil))
  end

  def execute_create
    # Only the target user can create their own grants
    unless @target_user == @current_user
      return render_action_error({
                                   action_name: "create_trustee_grant",
                                   resource: nil,
                                   error: "You can only create trustee grants for yourself",
                                 })
    end

    trusted_user = find_trusted_user(params[:trusted_user_id])
    unless trusted_user
      return render_action_error({
                                   action_name: "create_trustee_grant",
                                   resource: nil,
                                   error: "Trusted user not found",
                                 })
    end

    # Build permissions hash from params
    permissions = build_permissions_hash(params[:permissions])

    # Build studio scope
    studio_scope = build_studio_scope(params[:studio_scope_mode], params[:studio_ids])

    # Parse expiration
    expires_at = parse_expires_at(params[:expires_at])

    # Build relationship phrase
    relationship_phrase = params[:relationship_phrase].presence ||
                          "{trusted_user} acts for {granting_user}"

    grant = TrusteeGrant.new(
      tenant: @current_tenant,
      granting_user: @target_user,
      trusted_user: trusted_user,
      relationship_phrase: relationship_phrase,
      permissions: permissions,
      studio_scope: studio_scope,
      expires_at: expires_at
    )

    if grant.save
      # TODO: Send notification to trusted_user
      render_action_success({
                              action_name: "create_trustee_grant",
                              resource: grant,
                              result: "Trustee grant request sent to #{trusted_user.display_name || trusted_user.handle}",
                              redirect_to: trustee_grant_show_path(grant),
                            })
    else
      render_action_error({
                            action_name: "create_trustee_grant",
                            resource: nil,
                            error: grant.errors.full_messages.join(", "),
                          })
    end
  end

  # =========================================================================
  # ACCEPT TRUSTEE GRANT
  # =========================================================================

  def describe_accept
    render_action_description(ActionsHelper.action_description("accept_trustee_grant", resource: @grant))
  end

  def execute_accept
    unless @grant.trusted_user == @target_user
      return render_action_error({
                                   action_name: "accept_trustee_grant",
                                   resource: @grant,
                                   error: "You can only accept trustee grants granted to you",
                                 })
    end

    unless @grant.pending?
      return render_action_error({
                                   action_name: "accept_trustee_grant",
                                   resource: @grant,
                                   error: "This trustee grant is not pending",
                                 })
    end

    @grant.accept!

    render_action_success({
                            action_name: "accept_trustee_grant",
                            resource: @grant,
                            result: "Trustee grant accepted",
                            redirect_to: trustee_grant_show_path(@grant),
                          })
  end

  # =========================================================================
  # DECLINE TRUSTEE GRANT
  # =========================================================================

  def describe_decline
    render_action_description(ActionsHelper.action_description("decline_trustee_grant", resource: @grant))
  end

  def execute_decline
    unless @grant.trusted_user == @target_user
      return render_action_error({
                                   action_name: "decline_trustee_grant",
                                   resource: @grant,
                                   error: "You can only decline trustee grants granted to you",
                                 })
    end

    unless @grant.pending?
      return render_action_error({
                                   action_name: "decline_trustee_grant",
                                   resource: @grant,
                                   error: "This trustee grant is not pending",
                                 })
    end

    @grant.decline!

    render_action_success({
                            action_name: "decline_trustee_grant",
                            resource: @grant,
                            result: "Trustee grant declined",
                            redirect_to: trustee_grants_index_path,
                          })
  end

  # =========================================================================
  # REVOKE TRUSTEE GRANT
  # =========================================================================

  def describe_revoke
    render_action_description(ActionsHelper.action_description("revoke_trustee_grant", resource: @grant))
  end

  def execute_revoke
    unless @grant.granting_user == @target_user
      return render_action_error({
                                   action_name: "revoke_trustee_grant",
                                   resource: @grant,
                                   error: "You can only revoke trustee grants you created",
                                 })
    end

    if @grant.revoked? || @grant.declined?
      return render_action_error({
                                   action_name: "revoke_trustee_grant",
                                   resource: @grant,
                                   error: "This trustee grant is already revoked or declined",
                                 })
    end

    @grant.revoke!

    render_action_success({
                            action_name: "revoke_trustee_grant",
                            resource: @grant,
                            result: "Trustee grant revoked",
                            redirect_to: trustee_grant_show_path(@grant),
                          })
  end

  private

  def set_sidebar_mode
    @sidebar_mode = "minimal"
  end

  def require_login
    return if @current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to manage trustee grants.", status: :unauthorized }
    end
  end

  def set_target_user
    if params[:handle]
      tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
      raise ActiveRecord::RecordNotFound, "User not found" if tu.nil?

      @target_user = tu.user
    else
      @target_user = @current_user
    end

    # Verify user can manage trustee grants for this target
    authorize_grant_management
  end

  def set_grant
    grant_id = params[:grant_id]

    # Find grant by truncated_id, where target user is either granting or trusted
    @grant = TrusteeGrant.unscoped
      .where(tenant: @current_tenant)
      .includes(:granting_user, :trusted_user, :trustee_user)
      .find_by!(truncated_id: grant_id)

    # Verify target user is involved in this grant
    return if @grant.granting_user == @target_user || @grant.trusted_user == @target_user

    raise ActiveRecord::RecordNotFound, "Trustee grant not found"
  end

  def authorize_grant_management
    # User can manage their own trustee grants
    return if @target_user == @current_user

    respond_to do |format|
      format.html { redirect_to "/", alert: "You don't have permission to manage trustee grants for this user" }
      format.json { render json: { error: "Forbidden" }, status: :forbidden }
      format.md { render plain: "# Error\n\nYou don't have permission to manage trustee grants for this user.", status: :forbidden }
    end
  end

  def trustee_grants_index_path
    "/u/#{@target_user.handle}/settings/trustee-grants"
  end

  def trustee_grant_show_path(grant)
    "/u/#{@target_user.handle}/settings/trustee-grants/#{grant.truncated_id}"
  end

  def available_users_for_grant
    # Get users in the same tenant who can receive grants
    # Exclude current user, trustees, and users who already have grants
    existing_trusted_user_ids = TrusteeGrant.unscoped
      .where(granting_user: @target_user, tenant: @current_tenant)
      .where(revoked_at: nil, declined_at: nil)
      .pluck(:trusted_user_id)

    User.joins(:tenant_users)
      .where(tenant_users: { tenant_id: @current_tenant.id })
      .where.not(id: @target_user.id)
      .where.not(id: existing_trusted_user_ids)
      .where(user_type: ["person", "subagent"])
  end

  def find_trusted_user(user_id)
    return nil if user_id.blank?

    User.joins(:tenant_users)
      .where(tenant_users: { tenant_id: @current_tenant.id })
      .where.not(id: @target_user.id)
      .find_by(id: user_id)
  end

  def build_permissions_hash(permissions_param)
    return {} if permissions_param.blank?

    if permissions_param.is_a?(Array)
      permissions_param.index_with { true }
    elsif permissions_param.is_a?(Hash)
      permissions_param.transform_values { |v| ["true", true].include?(v) }
    elsif permissions_param.is_a?(String)
      permissions_param.split(",").map(&:strip).index_with { true }
    else
      {}
    end
  end

  def build_studio_scope(mode, studio_ids)
    mode = mode.presence || "all"

    case mode
    when "all"
      { "mode" => "all" }
    when "include"
      ids = parse_studio_ids(studio_ids)
      { "mode" => "include", "studio_ids" => ids }
    when "exclude"
      ids = parse_studio_ids(studio_ids)
      { "mode" => "exclude", "studio_ids" => ids }
    else
      { "mode" => "all" }
    end
  end

  def parse_studio_ids(studio_ids_param)
    return [] if studio_ids_param.blank?

    if studio_ids_param.is_a?(Array)
      studio_ids_param
    elsif studio_ids_param.is_a?(String)
      studio_ids_param.split(",").map(&:strip)
    else
      []
    end
  end

  def parse_expires_at(expires_at_param)
    return nil if expires_at_param.blank?

    Time.zone.parse(expires_at_param)
  rescue ArgumentError
    nil
  end
end
