# typed: false

class UsersController < ApplicationController
  include RequiresReverification

  allows_anonymous :show
  before_action :set_no_cache_headers, only: [:show]
  before_action :enforce_anonymous_read_rate_limit, only: [:show]

  before_action -> { require_reverification(scope: "representation") }, only: [:represent]
  before_action -> { require_reverification(scope: "email_change") }, only: [:update_email]

  def index
    @page_title = "Users"
    @sidebar_mode = "minimal"
    @users = current_tenant.tenant_users
  end

  # Redirect /settings to /u/:handle/settings
  def redirect_to_settings
    redirect_to "#{current_user.path}/settings"
  end

  # Redirect /settings/webhooks to /u/:handle/settings/webhooks
  def redirect_to_settings_webhooks
    redirect_to "#{current_user.path}/settings/webhooks"
  end

  def show
    @sidebar_mode = "minimal"
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @showing_user = tu.user
    @showing_user.tenant_user = tu
    @page_title = @showing_user.display_name
    @page_description = "#{@showing_user.display_name} on #{@current_tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    if params[:collective_handle]
      # Showing user in a specific collective
      sm = @showing_user.collective_members.where(collective: current_collective).first
      return render "404" if sm.nil?

      @showing_user.collective_member = sm
      @common_collectives = [current_collective]
      @additional_common_collective_count = if current_user
                                              (
                                                current_user.collectives & (@showing_user.collectives - [current_tenant.main_collective])
                                              ).select(&:listable?).count - 1
                                            else
                                              0
                                            end
    elsif current_user
      # Showing user at the tenant level, so we want to show all common collectives between the current user and the showing user
      @common_collectives = (current_user.collectives & (@showing_user.collectives - [current_tenant.main_collective])).select(&:listable?)
      @additional_common_collective_count = 0
    else
      # Anonymous viewer has no collective membership — no common collectives to show.
      @common_collectives = []
      @additional_common_collective_count = 0
    end

    # Compute count of common collectives for profile display
    if current_user && @current_user != @showing_user
      all_common = (current_user.collectives & (@showing_user.collectives - [current_tenant.main_collective])).select(&:listable?)
      @common_collective_count = all_common.count
    else
      @common_collective_count = 0
    end
    # Load AI agent count for human users
    if @showing_user.human?
      @ai_agent_count = @showing_user.ai_agents
        .joins(:tenant_users)
        .where(tenant_users: { tenant_id: current_tenant.id })
        .count
    end

    # Load proximity connections only when viewing your OWN profile.
    # Proximity exposes the profile owner's social graph and is private to
    # them — not visible to other logged-in users, not visible to anon.
    load_proximity_connections if @current_user == @showing_user

    # Build user's main collective (public) content timeline
    main_cid = @current_tenant.main_collective_id
    @feed_items = FeedBuilder.new(
      notes_scope: Note.unscope_collective
        .where(collective_id: main_cid, created_by_id: @showing_user.id),
      decisions_scope: Decision.unscope_collective
        .where(collective_id: main_cid, created_by_id: @showing_user.id),
      commitments_scope: Commitment.unscope_collective
        .where(collective_id: main_cid, created_by_id: @showing_user.id)
    ).feed_items

    respond_to do |format|
      format.html
      format.md
    end
  end

  def settings
    @sidebar_mode = "minimal"
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(@settings_user)

    @settings_user.tenant_user = tu
    @page_title = @settings_user == current_user ? "Your Settings" : "#{@settings_user.display_name}'s Settings"

    # For human users, show their AI agents
    if @settings_user.human?
      @ai_agents = @settings_user.ai_agents.includes(:tenant_users, :collective_members).where(tenant_users: { tenant_id: @current_tenant.id })
      # Collectives where settings user has invite permission (for adding AI agents)
      @invitable_collectives = @settings_user.collective_members.includes(:collective).select(&:can_invite?).map(&:collective)

      # Load all API tokens: user's own + AI agents' tokens
      # Sorted by: user's tokens first, then agents alphabetically, then by created_at desc
      user_tokens = @settings_user.api_tokens.external.includes(:user).to_a
      agent_tokens = @ai_agents.flat_map { |agent| agent.api_tokens.external.includes(:user).to_a }
      @all_api_tokens = user_tokens.sort_by { |t| -t.created_at.to_i } +
                        agent_tokens.sort_by { |t| [t.user.display_name.downcase, -t.created_at.to_i] }
    else
      @ai_agents = []
      @invitable_collectives = []
      @all_api_tokens = @settings_user.api_tokens.external.includes(:user).order(created_at: :desc).to_a
    end

    respond_to do |format|
      format.html
      format.md
    end
  end

  def add_ai_agent_to_collective
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: :not_found, plain: "404 Not Found" if tu.nil?

    ai_agent = tu.user
    return render status: :forbidden, plain: "403 Unauthorized" unless ai_agent.ai_agent? && ai_agent.parent_id == current_user.id

    collective = Collective.find(params[:collective_id])
    return render status: :forbidden, plain: "403 Unauthorized" unless current_user.can_add_ai_agent_to_collective?(ai_agent, collective)

    # Add AI agent to the collective
    collective.add_user!(ai_agent)

    respond_to do |format|
      format.json do
        render json: {
          collective_id: collective.id,
          collective_name: collective.name,
          collective_path: collective.path,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} has been added to #{collective.name}"
        redirect_to "#{current_user.path}/settings"
      end
    end
  end

  def remove_ai_agent_from_collective
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: :not_found, plain: "404 Not Found" if tu.nil?

    ai_agent = tu.user
    return render status: :forbidden, plain: "403 Unauthorized" unless ai_agent.ai_agent? && ai_agent.parent_id == current_user.id

    collective = Collective.find(params[:collective_id])
    collective_member = CollectiveMember.find_by(collective: collective, user: ai_agent)
    return render status: :not_found, plain: "404 Not Found" if collective_member.nil? || collective_member.archived?

    collective_member.archive!

    respond_to do |format|
      format.json do
        render json: {
          collective_id: collective.id,
          collective_name: collective.name,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} has been removed from #{collective.name}"
        redirect_to "#{current_user.path}/settings"
      end
    end
  end

  def update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(settings_user)

    if params[:name].present?
      settings_user.name = params[:name]
      settings_user.save!
      TenantUser.for_user_across_tenants(settings_user).update_all(
        display_name: params[:name]
      )
    end
    if params[:new_handle].present?
      tu.handle = params[:new_handle]
      tu.save!
      TenantUser.for_user_across_tenants(settings_user).where.not(id: tu.id).update_all(
        handle: params[:new_handle]
      )
    end
    # Handle identity_prompt for AI agents
    if settings_user.ai_agent? && params.key?(:identity_prompt)
      settings_user.agent_configuration ||= {}
      settings_user.agent_configuration["identity_prompt"] = params[:identity_prompt].presence
      settings_user.save!
    end
    # Handle mode for AI agents (internal vs external)
    if settings_user.ai_agent? && params.key?(:mode)
      settings_user.agent_configuration ||= {}
      mode = params[:mode]
      settings_user.agent_configuration["mode"] = ["internal", "external"].include?(mode) ? mode : "external"
      settings_user.save!
    end
    # Handle model for internal AI agents
    if settings_user.ai_agent? && params.key?(:model)
      settings_user.agent_configuration ||= {}
      settings_user.agent_configuration["model"] = params[:model].presence
      settings_user.save!
    end
    # Handle capabilities for AI agents
    # Checked = allowed, unchecked = blocked (standard checkbox model)
    # Empty array (all unchecked) = NO grantable actions allowed
    # nil (key absent) = all grantable actions allowed (backwards compatible default)
    if settings_user.ai_agent?
      settings_user.agent_configuration ||= {}
      capabilities = params[:capabilities]
      if capabilities.is_a?(Array) && capabilities.any?
        # Filter to only valid grantable actions
        valid_caps = capabilities & CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS
        settings_user.agent_configuration["capabilities"] = valid_caps
      else
        # All boxes unchecked = save empty array (nothing allowed)
        settings_user.agent_configuration["capabilities"] = []
      end
      settings_user.save!
    end
    flash[:notice] = "Profile updated successfully"
    redirect_to "#{settings_user.path}/settings"
  end

  # POST /u/:handle/settings/workspace_trio
  # Toggles Trio on/off in the user's private workspace. Only the workspace
  # owner can toggle. The collective-settings UI rejects writes against
  # workspaces (CollectivesController#update_settings returns 403), so this
  # endpoint is the user-facing entry point.
  def update_workspace_trio
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    settings_user = tu.user
    # Only the workspace owner toggles their own workspace flag.
    return render plain: "403 Unauthorized", status: :forbidden unless settings_user == current_user

    workspace = settings_user.private_workspace
    return render "404", status: :not_found if workspace.nil?

    will_be_trio = params[:feature_trio].to_s == "true"
    if will_be_trio && !workspace.tier_unlocks_paid_features?
      flash[:error] = "Trio requires the paid plan. Upgrade the workspace first."
      return redirect_to "#{settings_user.path}/settings"
    end

    workspace.set_feature_flag!("trio", will_be_trio)
    TrioActivator.reconcile!(workspace)

    flash[:notice] = "Workspace Trio is now #{workspace.trio_user_id.present? ? "enabled" : "disabled"}."
    redirect_to "#{settings_user.path}/settings"
  end

  # PATCH /u/:handle/settings/email
  EMAIL_CHANGE_TOKEN_EXPIRY = 24.hours

  def update_email
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(settings_user)

    new_email = params[:email]&.strip&.downcase
    if new_email.blank? || !new_email.match?(URI::MailTo::EMAIL_REGEXP)
      flash[:error] = "Please enter a valid email address."
      return redirect_to "#{settings_user.path}/settings"
    end

    if new_email == settings_user.email
      flash[:notice] = "That's already your email address."
      return redirect_to "#{settings_user.path}/settings"
    end

    if User.where.not(id: settings_user.id).exists?(email: new_email) ||
       OmniAuthIdentity.where.not(user_id: settings_user.id).exists?(email: new_email)
      flash[:error] = "That email address is already in use."
      return redirect_to "#{settings_user.path}/settings"
    end

    raw_token = SecureRandom.urlsafe_base64(32)
    settings_user.update!(
      pending_email: new_email,
      email_confirmation_token: Digest::SHA256.hexdigest(raw_token),
      email_confirmation_sent_at: Time.current
    )

    EmailChangeMailer.confirmation(settings_user, raw_token, current_tenant).deliver_later
    EmailChangeMailer.security_notice(settings_user, current_tenant).deliver_later

    flash[:notice] = "A confirmation email has been sent to #{new_email}. Please check your inbox."
    redirect_to "#{settings_user.path}/settings"
  end

  # DELETE /u/:handle/settings/email
  def cancel_email_change
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(settings_user)

    if settings_user.pending_email.present?
      settings_user.update!(pending_email: nil, email_confirmation_token: nil, email_confirmation_sent_at: nil)
      flash[:notice] = "Email change request has been cancelled."
    end
    redirect_to "#{settings_user.path}/settings"
  end

  # GET /u/:handle/settings/email/confirm/:token
  def confirm_email
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    user = tu.user

    # Guard: pending_email must exist (handles double-click and stale links)
    if user.pending_email.blank?
      flash[:notice] = "This email change has already been confirmed."
      return redirect_to "#{user.path}/settings"
    end

    hashed_token = Digest::SHA256.hexdigest(params[:token])
    unless ActiveSupport::SecurityUtils.secure_compare(user.email_confirmation_token.to_s, hashed_token)
      SecurityAuditLog.log_event(event: "email_confirmation_failure", severity: :warn,
                                 user_id: user.id, ip: request.remote_ip, reason: "invalid_token")
      flash[:error] = "Invalid or expired confirmation link."
      return redirect_to "#{user.path}/settings"
    end

    if user.email_confirmation_sent_at.blank? || user.email_confirmation_sent_at < EMAIL_CHANGE_TOKEN_EXPIRY.ago
      SecurityAuditLog.log_event(event: "email_confirmation_failure", severity: :warn,
                                 user_id: user.id, ip: request.remote_ip, reason: "expired_token")
      flash[:error] = "This confirmation link has expired. Please request a new email change."
      return redirect_to "#{user.path}/settings"
    end

    new_email = user.pending_email

    # Check-and-update in a transaction to prevent race conditions
    email_changed = false
    old_email = user.email
    ActiveRecord::Base.transaction do
      if User.where.not(id: user.id).exists?(email: new_email) ||
         OmniAuthIdentity.where.not(user_id: user.id).exists?(email: new_email)
        raise ActiveRecord::Rollback
      end

      user.update!(
        email: new_email,
        pending_email: nil,
        email_confirmation_token: nil,
        email_confirmation_sent_at: nil
      )
      user.omni_auth_identity&.update!(email: new_email)
      email_changed = true
    end

    if email_changed
      SecurityAuditLog.log_email_changed(user: user, old_email: old_email, ip: request.remote_ip)

      # Sync Stripe customer email (non-fatal, outside transaction)
      if user.stripe_customer&.active?
        begin
          Stripe::Customer.update(user.stripe_customer.stripe_id, { email: new_email })
        rescue Stripe::StripeError => e
          Rails.logger.warn("[UsersController] Stripe email sync failed: #{e.message}")
        end
      end

      flash[:notice] = "Your email address has been updated to #{new_email}."
    else
      # Email was claimed by another user — clear the stale pending state
      user.update!(pending_email: nil, email_confirmation_token: nil, email_confirmation_sent_at: nil)
      flash[:error] = "That email address has been claimed by another account since your request."
    end

    redirect_to "#{user.path}/settings"
  end

  # Start representing a user (typically an AI agent).
  # POST /u/:handle/represent
  def represent
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: :not_found, plain: "404 Not Found" if tu.nil?

    target_user = tu.user
    return render status: :forbidden, plain: "403 Unauthorized" unless target_user.ai_agent?
    return render status: :forbidden, plain: "403 Unauthorized" unless current_user.can_represent?(target_user)

    # Find the TrusteeGrant for this parent-ai_agent relationship
    grant = TrusteeGrant.active.find_by(
      granting_user: target_user,
      trustee_user: current_user
    )
    return render status: :forbidden, plain: "403 Unauthorized - No active grant" unless grant

    # Create a RepresentationSession for audit logging
    rep_session = api_helper.start_user_representation_session(grant: grant)

    # Set session cookies for representation (matches API headers)
    session[:representation_session_id] = rep_session.id
    session[:representing_user] = target_user.handle
    redirect_to "/representing"
  end

  # Stop representing a user.
  # DELETE /u/:handle/represent
  def stop_representing
    # Explicitly look up and end the representation session if present
    if session[:representation_session_id].present?
      rep_session = RepresentationSession.find_by(id: session[:representation_session_id])
      rep_session&.end!
    end
    clear_representation!
    redirect_to request.referer || root_path
  end

  def update_image
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(settings_user)

    if params[:image].present?
      settings_user.image = params[:image]
    elsif params[:cropped_image_data].present?
      settings_user.cropped_image_data = params[:cropped_image_data]
    else
      return render status: :bad_request, plain: "400 Bad Request"
    end
    settings_user.save!
    redirect_to request.referer || "#{settings_user.path}/settings"
  end

  # Markdown API actions

  def actions_index
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(@settings_user)

    @page_title = @settings_user == current_user ? "Actions | Your Settings" : "Actions | #{@settings_user.display_name}'s Settings"
    render_actions_index(ActionsHelper.actions_for_route("/u/:handle/settings"))
  end

  def describe_update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(@settings_user)

    render_action_description(ActionsHelper.action_description("update_profile", resource: @settings_user))
  end

  def execute_update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(@settings_user)

    if params[:name].present?
      @settings_user.name = params[:name]
      @settings_user.save!
      TenantUser.for_user_across_tenants(@settings_user).update_all(display_name: params[:name])
    end
    # Use new_handle to avoid conflict with path parameter :handle
    # Note: handle is a virtual attribute that delegates to tenant_user
    if params[:new_handle].present?
      tu.handle = params[:new_handle]
      tu.save!
      TenantUser.for_user_across_tenants(@settings_user).where.not(id: tu.id).update_all(handle: params[:new_handle])
    end

    @settings_user.tenant_user = tu
    @page_title = @settings_user == current_user ? "Your Settings" : "#{@settings_user.display_name}'s Settings"

    # For human users, show their AI agents and consolidated API tokens
    if @settings_user.human?
      @ai_agents = @settings_user.ai_agents.includes(:tenant_users, :collective_members).where(tenant_users: { tenant_id: @current_tenant.id })
      @invitable_collectives = @settings_user.collective_members.includes(:collective).select(&:can_invite?).map(&:collective)

      # Load all API tokens: user's own + AI agents' tokens
      user_tokens = @settings_user.api_tokens.external.includes(:user).to_a
      agent_tokens = @ai_agents.flat_map { |agent| agent.api_tokens.external.includes(:user).to_a }
      @all_api_tokens = user_tokens.sort_by { |t| -t.created_at.to_i } +
                        agent_tokens.sort_by { |t| [t.user.display_name.downcase, -t.created_at.to_i] }
    else
      @ai_agents = []
      @invitable_collectives = []
      @all_api_tokens = @settings_user.api_tokens.external.includes(:user).order(created_at: :desc).to_a
    end

    respond_to do |format|
      format.md { render "settings" }
      format.html { redirect_to "#{@settings_user.path}/settings" }
    end
  end

  # ---- UserList: "add to list" gesture ----

  def describe_add_to_list
    return render "shared/404", status: :not_found if showing_user_from_handle.nil?

    render_action_description(ActionsHelper.action_description("add_to_list", resource: showing_user_from_handle))
  end

  def execute_add_to_list
    target = showing_user_from_handle
    return list_action_not_found("add_to_list") if target.nil?
    return list_action_unauthenticated("add_to_list") if @current_user.nil?

    if target.id == @current_user.id
      return render_action_error({
                                   action_name: "add_to_list",
                                   resource: target,
                                   error: "You cannot add yourself to your own list.",
                                 })
    end

    list = @current_user.primary_user_list_in!(@current_tenant)
    membership = list.user_list_members.find_or_initialize_by(user_id: target.id)
    return render_action_success({ action_name: "add_to_list", resource: target, result: "Already on your list." }) if membership.persisted?

    membership.added_by = @current_user
    if membership.save
      render_action_success({ action_name: "add_to_list", resource: target, result: "Added to your list." })
    else
      render_action_error({
                            action_name: "add_to_list",
                            resource: target,
                            error: membership.errors.full_messages.join(", "),
                          })
    end
  end

  def describe_remove_from_list
    return render "shared/404", status: :not_found if showing_user_from_handle.nil?

    render_action_description(ActionsHelper.action_description("remove_from_list", resource: showing_user_from_handle))
  end

  def execute_remove_from_list
    target = showing_user_from_handle
    return list_action_not_found("remove_from_list") if target.nil?
    return list_action_unauthenticated("remove_from_list") if @current_user.nil?

    list = UserList
      .tenant_scoped_only(@current_tenant.id)
      .where(owner_id: @current_user.id, is_primary: true, deleted_at: nil)
      .first

    membership = list&.user_list_members&.find_by(user_id: target.id)
    membership&.destroy!

    result = membership ? "Removed from your list." : "Not on your list."
    render_action_success({ action_name: "remove_from_list", resource: target, result: result })
  end

  private

  def showing_user_from_handle
    return @showing_user_from_handle if defined?(@showing_user_from_handle)

    tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
    @showing_user_from_handle = tu&.user
  end

  def list_action_not_found(action_name)
    render_action_error({ action_name: action_name, error: "User not found.", status: :not_found })
  end

  def list_action_unauthenticated(action_name)
    render_action_error({ action_name: action_name, error: "You must be logged in.", status: :unauthorized })
  end

  # ---- end UserList action helpers ----

  def token_authenticated_action?
    action_name == "confirm_email"
  end

  # Load proximity connections for the user profile being viewed
  # Returns a simple sorted list of the most proximate users
  def load_proximity_connections
    all_connections = @showing_user.most_proximate_users(tenant_id: current_tenant.id, limit: 30)

    @proximity_users = all_connections.filter_map do |user, _score|
      next if user.nil? || user.archived?

      tu = user.tenant_users.find_by(tenant_id: current_tenant.id)
      next if tu.nil?

      user.tenant_user = tu
      user
    end
  end
end
