# typed: false

class UsersController < ApplicationController
  include RequiresReverification
  include NotificationPreferencesParams

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

  AVAILABLE_PROFILE_TABS = ["posts", "activity", "lists", "common_collectives"].freeze
  DEFAULT_PROFILE_TAB = "posts"

  def show
    @sidebar_mode = "minimal"
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @showing_user = tu.user
    @showing_user.tenant_user = tu
    @page_scope = "visibility:public creator:@#{tu.handle}"
    @page_title = @showing_user.display_name
    @page_description = "#{@showing_user.display_name} on #{@current_tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    load_profile_header_data

    # Legacy /c/:handle/u/:user_handle path uses the same action; load the
    # specific-collective common-collectives data eagerly so the 404 fires
    # before tab resolution.
    if params[:collective_handle]
      load_profile_common_collectives_data
      return if performed?
    end

    @active_tab = resolve_active_profile_tab(params[:tab])

    if request.format.md?
      load_profile_common_collectives_data unless @common_collectives
      load_profile_lists_data
      load_profile_posts_data
      load_profile_activity_data
    else
      case @active_tab
      when "lists"               then load_profile_lists_data
      when "common_collectives"  then load_profile_common_collectives_data unless @common_collectives
      when "activity"            then load_profile_activity_data
      else                            load_profile_posts_data
      end
    end

    respond_to do |format|
      format.html
      format.md
    end
  end

  def mutuals
    @sidebar_mode = "minimal"
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @showing_user = tu.user
    @showing_user.tenant_user = tu

    # ?filter=common narrows the list to mutuals shared with the viewer
    # (only meaningful for a logged-in viewer who isn't the profile user).
    can_apply_common = @current_user.present? && @current_user.id != @showing_user.id
    @filter = params[:filter] == "common" && can_apply_common ? "common" : nil
    @page_title = @filter == "common" ? "Mutuals in common · #{@showing_user.display_name}" : "Mutuals · #{@showing_user.display_name}"

    ids = @showing_user.mutual_user_ids_in(@current_tenant)
    ids &= @current_user.mutual_user_ids_in(@current_tenant) if @filter == "common"

    @mutuals = if ids.empty?
                 []
               else
                 TenantUser
                   .where(tenant_id: @current_tenant.id, user_id: ids)
                   .includes(:user)
                   .map do |t|
                   u = t.user
                   u.tenant_user = t
                   u
                 end
               end

    # On someone else's mutuals page, the viewer hasn't necessarily tuned
    # in to those people — show tune-in buttons per row. On the viewer's
    # OWN mutuals page, every row is reciprocal by definition, so we skip
    # the precompute (the partial would short-circuit anyway since the
    # viewer's own primary list contains all of them).
    @show_tune_in_on_mutuals = @current_user.present? && @current_user.id != @showing_user.id
    @tune_in_state = if @show_tune_in_on_mutuals
                       TuneInState.compute(
                         viewer: @current_user,
                         target_ids: @mutuals.map(&:id),
                         tenant: @current_tenant
                       )
                     end

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

    # AI agents have a single canonical settings surface at
    # /ai-agents/<handle>/settings. /u/<agent>/settings used to host a
    # parallel form; redirect to consolidate.
    return redirect_to ai_agent_settings_path(@settings_user.handle) if @settings_user.ai_agent?

    @settings_user.tenant_user = tu
    @page_title = @settings_user == current_user ? "Your Settings" : "#{@settings_user.display_name}'s Settings"

    @ai_agents = @settings_user.ai_agents.includes(:tenant_users, :collective_members).where(tenant_users: { tenant_id: @current_tenant.id })

    # Load all API tokens the user is responsible for: their own + every AI
    # agent they own. The per-agent settings page also lists each agent's
    # tokens; this is the aggregate view.
    user_tokens = @settings_user.api_tokens.external.includes(:user).to_a
    agent_tokens = @ai_agents.flat_map { |agent| agent.api_tokens.external.includes(:user).to_a }
    @all_api_tokens = user_tokens.sort_by { |t| -t.created_at.to_i } +
                      agent_tokens.sort_by { |t| [t.user.display_name.downcase, -t.created_at.to_i] }

    @notification_webhook = AutomationRule.tenant_scoped_only.notification_webhook_for(@settings_user).first

    # Live refresh tokens = trusted devices (one per family; rotated
    # predecessors are excluded, see RefreshToken.live). Sorted with the
    # current device first (so the user sees themselves at the top), then by
    # most recently used.
    @active_devices = @settings_user.refresh_tokens.live.order(last_used_at: :desc).to_a
    @active_devices.sort_by! { |d| [current_refresh_token&.id == d.id ? 0 : 1, -d.last_used_at.to_i] }

    @push_subscriptions = @settings_user.web_push_subscriptions.active.order(last_seen_at: :desc).to_a

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
      # All-or-nothing across the user's tenants, through validated saves —
      # update_all would skip the uniqueness validation and could leave the
      # rename half-applied when another tenant has a collision.
      ActiveRecord::Base.transaction do
        tu.handle = params[:new_handle]
        tu.save!
        TenantUser.for_user_across_tenants(settings_user).where.not(id: tu.id).find_each do |other|
          other.update!(handle: tu.handle)
        end
      end
    end

    # Bio / location / website are per-tenant — write straight to the
    # TenantUser. Use `key?` so a deliberate empty string clears the field
    # but not submitting the field at all leaves it untouched.
    [:bio, :location, :website].each do |field|
      tu[field] = params[field].to_s.strip.presence if params.key?(field)
    end
    tu.save!

    flash[:notice] = "Profile updated successfully"
    redirect_to "#{settings_user.path}/settings"
  rescue ActiveRecord::RecordInvalid => e
    flash[:alert] = e.record.errors.full_messages.to_sentence
    redirect_to "#{settings_user.path}/settings"
  rescue ActiveRecord::RecordNotUnique
    # Race backstop: the uniqueness validation passed concurrently with
    # another claim on the same handle and the DB index fired.
    flash[:alert] = "That handle is already taken."
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

  # POST /u/:handle/settings/notifications
  # HTML form submit of the full notification preference matrix.
  def update_notification_preferences
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(settings_user)

    tu.update_notification_preferences!(
      notification_preferences_from_params(complete: true, channels: current_tenant.editable_notification_channels)
    )

    flash[:notice] = "Notification preferences updated"
    redirect_to "#{settings_user.path}/settings"
  end

  def describe_update_notification_preferences
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(@settings_user)

    render_action_description(ActionsHelper.action_description("update_notification_preferences", resource: @settings_user))
  end

  # POST /u/:handle/settings/actions/update_notification_preferences
  # Markdown action surface: partial merge of the supplied channel toggles.
  def execute_update_notification_preferences
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "404", status: :not_found if tu.nil?

    @settings_user = tu.user
    return render plain: "403 Unauthorized", status: :forbidden unless current_user.can_edit?(@settings_user)

    tu.update_notification_preferences!(notification_preferences_from_params(complete: false))

    render_action_success({
                            action_name: "update_notification_preferences",
                            resource: @settings_user,
                            result: "Notification preferences updated",
                            redirect_to: "#{@settings_user.path}/settings",
                          })
  end

  # ---- UserList: "tune in" gesture ----

  def describe_tune_in
    return render "shared/404", status: :not_found if showing_user_from_handle.nil?

    render_action_description(ActionsHelper.action_description("tune_in", resource: showing_user_from_handle))
  end

  def execute_tune_in
    target = showing_user_from_handle
    return list_action_not_found("tune_in") if target.nil?
    return list_action_unauthenticated("tune_in") if @current_user.nil?

    if target.id == @current_user.id
      return render_action_error({
                                   action_name: "tune_in",
                                   resource: target,
                                   error: "You can't tune in to yourself.",
                                 })
    end

    list = @current_user.primary_user_list_in!(@current_tenant)
    membership = list.user_list_members.find_or_initialize_by(user_id: target.id)
    return render_action_success({ action_name: "tune_in", resource: target, result: "Already tuned in." }) if membership.persisted?

    membership.added_by = @current_user
    if membership.save
      render_action_success({ action_name: "tune_in", resource: target, result: "Tuned in." })
    else
      render_action_error({
                            action_name: "tune_in",
                            resource: target,
                            error: membership.errors.full_messages.join(", "),
                          })
    end
  end

  def describe_tune_out
    return render "shared/404", status: :not_found if showing_user_from_handle.nil?

    render_action_description(ActionsHelper.action_description("tune_out", resource: showing_user_from_handle))
  end

  def execute_tune_out
    target = showing_user_from_handle
    return list_action_not_found("tune_out") if target.nil?
    return list_action_unauthenticated("tune_out") if @current_user.nil?

    list = UserList
      .tenant_scoped_only(@current_tenant.id)
      .where(owner_id: @current_user.id, is_primary: true, deleted_at: nil)
      .first

    membership = list&.user_list_members&.find_by(user_id: target.id)
    membership&.destroy!

    result = membership ? "Tuned out." : "Not tuned in."
    render_action_success({ action_name: "tune_out", resource: target, result: result })
  end

  private

  # Returns [target_on_my_list, viewer_on_target_list] for the profile
  # header's tuning-in state. Two queries: one to resolve both primary
  # lists by owner, one OR'd existence check covering both directions.
  def compute_mutual_tune_in_state
    return [false, false] unless @current_user && @showing_user && @current_user.id != @showing_user.id

    list_id_by_owner = UserList
      .tenant_scoped_only(@current_tenant.id)
      .where(owner_id: [@current_user.id, @showing_user.id], is_primary: true, deleted_at: nil)
      .pluck(:owner_id, :id)
      .to_h
    my_list_id     = list_id_by_owner[@current_user.id]
    target_list_id = list_id_by_owner[@showing_user.id]
    return [false, false] if my_list_id.nil? && target_list_id.nil?

    matches = UserListMember
      .where(
        "(user_list_id = ? AND user_id = ?) OR (user_list_id = ? AND user_id = ?)",
        my_list_id, @showing_user.id, target_list_id, @current_user.id
      )
      .pluck(:user_list_id)
      .to_set

    [
      my_list_id.present? && matches.include?(my_list_id),
      target_list_id.present? && matches.include?(target_list_id),
    ]
  end

  def load_profile_header_data
    # `listable_common` is needed both for the header count and (later) for
    # the Common Collectives tab body — memoize on the instance so we don't
    # repeat the intersection.
    @listable_common = if current_user
                         (current_user.collectives & (@showing_user.collectives - [@current_tenant.main_collective])).select(&:listable?)
                       else
                         []
                       end

    @common_collective_count = if current_user && @current_user != @showing_user
                                 @listable_common.count
                               else
                                 0
                               end

    if @showing_user.human?
      @ai_agent_count = @showing_user.ai_agents
        .joins(:tenant_users)
        .where(tenant_users: { tenant_id: @current_tenant.id })
        .count
    end

    @target_on_my_list, @viewer_on_target_list = compute_mutual_tune_in_state
    @viewer_blocks_target     = @current_user.present? && @current_user.blocked?(@showing_user)
    @viewer_blocked_by_target = @current_user.present? && @current_user.blocked_by?(@showing_user)

    target_mutual_ids = @showing_user.mutual_user_ids_in(@current_tenant)
    @mutuals_count = target_mutual_ids.size
    @mutuals_in_common_count = if @current_user && @current_user.id != @showing_user.id
                                 viewer_mutual_ids = @current_user.mutual_user_ids_in(@current_tenant)
                                 (target_mutual_ids & viewer_mutual_ids).size
                               end

    @blocked_either_way = @viewer_blocks_target || @viewer_blocked_by_target
    # Lists are also needed in the Lists tab body — cache the array so the
    # tab loader doesn't re-query.
    @showing_user_lists = visible_lists_owned_by_for_profile(@showing_user)
    @showing_user_lists_count = @showing_user_lists.size
  end

  def load_profile_common_collectives_data
    if params[:collective_handle]
      # Showing user in a specific collective (legacy /c/.../u/:handle).
      sm = @showing_user.collective_members.where(collective: @current_collective).first
      return render "404" if sm.nil?

      @showing_user.collective_member = sm
      @common_collectives = [@current_collective]
      @additional_common_collective_count = [@listable_common.count - 1, 0].max
    elsif current_user
      @common_collectives = @listable_common
      @additional_common_collective_count = 0
    else
      @common_collectives = []
      @additional_common_collective_count = 0
    end
  end

  def load_profile_lists_data
    @showing_user_lists ||= visible_lists_owned_by_for_profile(@showing_user)
  end

  def load_profile_posts_data
    @posts_feed_items = FeedBuilder.new(
      notes_scope: Note.main_collective_scope(@current_tenant).where(created_by_id: @showing_user.id, subtype: "post"),
      decisions_scope: Decision.none,
      commitments_scope: Commitment.none
    ).feed_items
  end

  def load_profile_activity_data
    @activity_feed_items = FeedBuilder.new(
      notes_scope: Note.main_collective_scope(@current_tenant).where(created_by_id: @showing_user.id).where.not(subtype: "post"),
      decisions_scope: Decision.main_collective_scope(@current_tenant).where(created_by_id: @showing_user.id),
      commitments_scope: Commitment.main_collective_scope(@current_tenant).where(created_by_id: @showing_user.id)
    ).feed_items
  end

  def resolve_active_profile_tab(requested)
    return DEFAULT_PROFILE_TAB if @blocked_either_way
    return DEFAULT_PROFILE_TAB unless AVAILABLE_PROFILE_TABS.include?(requested)
    return DEFAULT_PROFILE_TAB if requested == "common_collectives" && !show_profile_common_collectives_tab?

    requested
  end

  def show_profile_common_collectives_tab?
    @current_user && @current_user != @showing_user && @common_collective_count > 0
  end
  helper_method :show_profile_common_collectives_tab?

  def visible_lists_owned_by_for_profile(owner)
    base = UserList
      .tenant_scoped_only(@current_tenant.id)
      .where(owner_id: owner.id, deleted_at: nil)
      .includes(:user_list_members, :members, :collective)
      .order(is_primary: :desc, created_at: :asc)

    return base.to_a if @current_user && @current_user.id == owner.id
    return [] if @current_user.nil?

    coll_ids = CollectiveMember
      .where(user_id: @current_user.id)
      .joins(:collective).where(collectives: { tenant_id: @current_tenant.id })
      .pluck(:collective_id)
    base.where(visibility: "public", collective_id: coll_ids).to_a
  end

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
end
