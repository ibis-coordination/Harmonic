# typed: false

class ApplicationController < ActionController::Base
  # Session timeout configuration (in seconds)
  SESSION_ABSOLUTE_TIMEOUT = (ENV["SESSION_ABSOLUTE_TIMEOUT"]&.to_i || 24.hours).seconds
  SESSION_IDLE_TIMEOUT = (ENV["SESSION_IDLE_TIMEOUT"]&.to_i || 2.hours).seconds

  before_action :check_auth_subdomain, :current_app, :current_tenant, :current_collective,
                :current_path, :current_user, :current_resource, :current_representation_session, :current_heartbeat,
                :load_unread_notification_count, :set_sentry_context
  before_action :check_session_timeout
  before_action :check_user_suspension

  # Include ActionCapabilityCheck AFTER before_action declarations so that
  # append_before_action puts check_capability_for_action at the END of the chain,
  # after current_user is set
  include ActionCapabilityCheck

  skip_before_action :verify_authenticity_token, if: :api_token_present?

  def check_auth_subdomain
    return if single_tenant_mode?

    return unless request.subdomain == auth_subdomain && !is_auth_controller?

    redirect_to "/login"
  end

  def single_tenant_mode?
    ENV["SINGLE_TENANT_MODE"] == "true"
  end

  def current_app
    # TODO: Remove this method. Logic is not longer needed.
    # This method should be overridden in the app-specific controllers.
    return @current_app if defined?(@current_app)

    @current_app = "decisive"
    @current_app_title = "Harmonic"
    @current_app_description = "social agency platform"
    @current_app
  end

  def current_tenant
    return @current_tenant if defined?(@current_tenant)

    current_collective
    @current_tenant ||= @current_collective.tenant
    redirect_to "/404" if @current_tenant.archived?
    @current_tenant
  end

  def current_collective
    return @current_collective if defined?(@current_collective)

    # begin
    # Collective.scope_thread_to_collective sets the current collective and tenant based on the subdomain and handle
    # and raises an error if the subdomain or handle is not found.
    # Default scope is configured in ApplicationRecord to scope all queries to
    # Tenant.current_tenant_id and Collective.current_collective_id
    # and automatically set tenant_id and collective_id on any new records.
    @current_collective = Collective.scope_thread_to_collective(
      subdomain: request.subdomain,
      handle: params[:collective_handle]
    )
    @current_tenant = @current_collective.tenant
    # Set these associations to avoid unnecessary reloading.
    @current_collective.tenant = @current_tenant
    @current_tenant.main_collective = @current_collective if @current_tenant.main_collective_id == @current_collective.id
    # rescue
    #   raise ActionController::RoutingError.new('Not Found')
    # end
    @current_collective
  end

  def current_path
    @current_path ||= request.path
  end

  def api_token_present?
    request.headers["Authorization"].present?
  end

  def current_token
    return @current_token if defined?(@current_token)
    return @current_token = nil unless api_token_present?

    prefix, token_string = request.headers["Authorization"].split(" ")
    @current_token = ApiToken.authenticate(token_string, tenant_id: current_tenant.id)
    return nil unless @current_token

    if prefix == "Bearer" && @current_token&.active?
      @current_token.token_used!
    elsif prefix == "Bearer" && @current_token&.expired? && !@current_token.deleted?
      render json: { error: "Token expired" }, status: :unauthorized
    else
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
    @current_token
  end

  def api_authorize!
    # Internal tokens bypass API enabled checks - they are system-managed
    # and used for internal operations like agent runners
    unless current_token&.internal? || (current_collective.api_enabled? && current_tenant.api_enabled?)
      collective_or_tenant = current_tenant.api_enabled? ? "studio" : "tenant"
      return render json: { error: "API not enabled for this #{collective_or_tenant}" }, status: :forbidden
    end
    return render json: { error: "API only supports JSON or Markdown formats" }, status: :forbidden unless json_or_markdown_request?

    request.format = :md unless request.format == :json
    current_token || render(json: { error: "Unauthorized" }, status: :unauthorized)
  end

  def json_or_markdown_request?
    # API tokens can only access JSON and Markdown endpoints.
    request.headers["Accept"] == "application/json" ||
      request.headers["Accept"] == "text/markdown" ||
      request.headers["Content-Type"] == "application/json" ||
      request.headers["Content-Type"] == "text/markdown" ||
      request.path.starts_with?("/api/") # Allow all API endpoints
  end

  # Determines the current user for this request.
  #
  # There are two authentication paths:
  # 1. API token authentication (Authorization header present)
  # 2. Browser session authentication (cookie-based)
  #
  # Both paths support representation sessions:
  # - API: via X-Representation-Session-ID + X-Representing-User/Studio headers
  # - Browser: via representation_session_id + representing_user/studio cookies
  #
  # The effective current_user is either the base human user or the trustee user
  # from an active representation session.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = if api_token_present?
                      resolve_api_user
                    else
                      resolve_browser_session_user
                    end
  end

  private

  # Resolves user identity for API token-authenticated requests.
  #
  # Supports representation via X-Representation-Session-ID header.
  # This mirrors the browser flow where a RepresentationSession must be started first.
  def resolve_api_user
    api_authorize!
    # NOTE: must set @current_user before calling validate_scope to avoid infinite loop
    user = @current_token&.user
    return nil if user.nil?

    # Set @current_user temporarily for validate_scope (which calls current_user)
    @current_user = user
    validate_scope

    # Handle representation through the API
    session_id = request.headers["X-Representation-Session-ID"]

    if session_id.present?
      resolve_api_representation(user, session_id)
    else
      check_for_active_representation_session(user)
    end
  end

  # Validates and applies API representation from X-Representation-Session-ID header.
  #
  # Requires additional security headers for non-DELETE requests:
  # - User representation: X-Representing-User header with granting user's handle
  # - Studio representation: X-Representing-Studio header with studio's handle
  #
  # @param user [User] The token's user (representative)
  # @param session_id [String] The representation session ID from header (full UUID or truncated_id)
  # @return [User] The trustee user if valid, or renders error and returns nil
  def resolve_api_representation(user, session_id)
    # Store the original token user for use in session-ending operations
    @api_token_user = user

    # Look up the RepresentationSession by ID
    # Support both full UUID and 8-char truncated_id
    column = session_id.length == 8 ? "truncated_id" : "id"
    rep_session = RepresentationSession.find_by(column => session_id, tenant_id: current_tenant.id)

    # Validate: session exists
    unless rep_session
      render json: { error: "Invalid representation session ID" }, status: :forbidden
      return nil
    end

    # Validate: session is active (not ended)
    if rep_session.ended?
      render json: { error: "Representation session has ended" }, status: :forbidden
      return nil
    end

    # Validate: session is not expired
    if rep_session.expired?
      render json: { error: "Representation session has expired" }, status: :forbidden
      return nil
    end

    # Validate: grant is still active (for user representation sessions)
    if rep_session.trustee_grant && !rep_session.trustee_grant.active?
      render json: { error: "Trustee grant is no longer active" }, status: :forbidden
      return nil
    end

    # Validate: token's user matches session's representative_user
    unless rep_session.representative_user_id == user.id
      render json: { error: "Token user is not the session's representative" }, status: :forbidden
      return nil
    end

    # Validate representing headers (skip for session-ending DELETE requests)
    return nil if !ending_representation_session? && !validate_representing_headers(rep_session)

    # All validations passed - apply representation
    @current_representation_session = rep_session
    @current_user = rep_session.effective_user
    rep_session.effective_user
  end

  # Validates the X-Representing-User or X-Representing-Studio header based on session type.
  # This adds an extra layer of security by requiring the API client to know exactly
  # who or what they are representing.
  #
  # @param session [RepresentationSession] The representation session
  # @return [Boolean] true if valid, false if error was rendered
  def validate_representing_headers(session)
    if session.user_representation?
      # User representation requires X-Representing-User header
      representing_user_header = request.headers["X-Representing-User"]
      expected_handle = session.trustee_grant&.granting_user&.handle

      unless representing_user_header.present?
        render json: { error: "X-Representing-User header required for user representation" }, status: :forbidden
        return false
      end

      unless representing_user_header == expected_handle
        render json: { error: "X-Representing-User header does not match the represented user" }, status: :forbidden
        return false
      end
    else
      # Studio representation requires X-Representing-Studio header
      representing_studio_header = request.headers["X-Representing-Studio"]
      expected_handle = session.collective&.handle

      unless representing_studio_header.present?
        render json: { error: "X-Representing-Studio header required for studio representation" }, status: :forbidden
        return false
      end

      unless representing_studio_header == expected_handle
        render json: { error: "X-Representing-Studio header does not match the represented studio" }, status: :forbidden
        return false
      end
    end

    true
  end

  # Checks if the current request is ending a representation session.
  # These requests don't require the X-Representing-* headers.
  #
  # @return [Boolean] true if this is a session-ending request
  def ending_representation_session?
    return false unless request.delete?

    # DELETE /representing - end user representation
    # DELETE /studios/:handle/represent - end studio representation
    # DELETE /studios/:handle/r/:id - end specific session
    # DELETE /scenes/:handle/represent - end studio representation (scenes)
    # DELETE /scenes/:handle/r/:id - end specific session (scenes)
    request.path == "/representing" ||
      request.path.match?(%r{^/studios/[^/]+/represent$}) ||
      request.path.match?(%r{^/studios/[^/]+/r/[^/]+$}) ||
      request.path.match?(%r{^/scenes/[^/]+/represent$}) ||
      request.path.match?(%r{^/scenes/[^/]+/r/[^/]+$})
  end

  # Checks if the user has any active representation sessions when no header is provided.
  # Returns 409 Conflict if active session exists, forcing explicit intent.
  #
  # @param user [User] The token's user
  # @return [User] The user if no active sessions, or renders error and returns nil
  def check_for_active_representation_session(user)
    # Check for active representation sessions where this user is the representative
    # Uses tenant_scoped_only to bypass collective scope but keep tenant scope
    active_session = RepresentationSession.tenant_scoped_only(current_tenant.id).where(
      representative_user_id: user.id,
      ended_at: nil
    ).where("began_at > ?", 24.hours.ago).first

    if active_session
      render json: {
        error: "Active representation session exists. Include X-Representation-Session-ID header to act as trustee, or end the session first.",
        active_session_id: active_session.id,
      }, status: :conflict
      return nil
    end

    # No active session - proceed as the token's user
    user
  end

  # Resolves user identity for browser session-authenticated requests.
  #
  # Uses cookies that mirror the API header structure:
  # - representation_session_id: ID of the RepresentationSession
  # - representing_user: handle of the user being represented
  # - representing_studio: handle of the studio being represented
  def resolve_browser_session_user
    load_session_user
    resolve_browser_representation
    validate_access
    @current_user
  end

  # Loads the base human user from session.
  #
  # Session key :user_id stores the logged-in human user.
  # Only human users can log in via browser.
  def load_session_user
    @current_human_user = (User.find_by(id: session[:user_id], user_type: "human") if session[:user_id].present?)
    @current_user = @current_human_user
  end

  # Resolves representation from browser cookies.
  #
  # Mirrors the API header validation logic:
  # - Validates representation_session_id exists and is active
  # - Validates representing_user/studio cookie matches session target
  # - Sets @current_user to the trustee user if valid
  def resolve_browser_representation
    return unless session[:representation_session_id].present?
    return unless @current_human_user

    # Look up the RepresentationSession (bypass collective scope)
    rep_session = RepresentationSession.tenant_scoped_only(current_tenant.id).find_by(
      id: session[:representation_session_id]
    )

    # Validate: session exists
    unless rep_session
      clear_representation!
      return
    end

    # Validate: session is active (not ended)
    if rep_session.ended?
      clear_representation!
      return
    end

    # Validate: session is not expired
    if rep_session.expired?
      clear_representation!
      flash[:alert] = "Representation session expired."
      return
    end

    # Validate: grant is still active (for user representation sessions)
    if rep_session.trustee_grant && !rep_session.trustee_grant.active?
      clear_representation!
      flash[:alert] = "Trustee grant is no longer active."
      return
    end

    # Validate: human user matches session's representative_user
    unless rep_session.representative_user_id == @current_human_user.id
      clear_representation!
      return
    end

    # Validate: representing cookie matches session target
    unless validate_representing_cookies(rep_session)
      clear_representation!
      return
    end

    # All validations passed - apply representation
    @current_representation_session = rep_session
    @current_user = rep_session.effective_user
  end

  # Validates the representing_user or representing_studio cookie matches the session.
  #
  # @param rep_session [RepresentationSession] The representation session
  # @return [Boolean] true if valid, false otherwise
  def validate_representing_cookies(rep_session)
    if rep_session.user_representation?
      # User representation requires representing_user cookie
      representing_user = session[:representing_user]
      expected_handle = rep_session.trustee_grant&.granting_user&.handle
      representing_user.present? && representing_user == expected_handle
    else
      # Studio representation requires representing_studio cookie
      representing_studio = session[:representing_studio]
      expected_handle = rep_session.collective&.handle
      representing_studio.present? && representing_studio == expected_handle
    end
  end

  # Validates access for the resolved user identity.
  def validate_access
    if @current_user
      validate_authenticated_access
    else
      validate_unauthenticated_access
    end
  end

  public

  def current_invite
    return @current_invite if defined?(@current_invite)

    @current_invite = if params[:code] || cookies[:invite_code]
                        Invite.find_by(
                          collective: current_collective,
                          code: params[:code] || cookies[:invite_code]
                        )
                      end
    @current_invite
  end

  def validate_authenticated_access
    tu = @current_tenant.tenant_users.find_by(user: @current_user)
    if tu.nil?
      accepting_invite = current_invite && current_invite.collective == @current_collective
      if @current_tenant.require_login? && controller_name != "sessions" && !accepting_invite
        @sidebar_mode = "none"
        render status: :forbidden, layout: "application", template: "sessions/403_to_logout"
      elsif accepting_invite && current_invite.is_acceptable_by_user?(@current_user)
        # The user still has to click "accept" to accept the invite to the collective,
        # but they need to access the tenant to do so.
        # Not sure how to handle the case where the user does not accept the invite.
        # Should we remove the tenant_user record somehow?
        # Should we require that all tenant users be a member of at least one (non-main) collective?
        @current_tenant.add_user!(@current_user)
      end
    else
      # This assignment prevents unnecessary reloading.
      @current_user.tenant_user = tu
    end

    # Check grant studio scope for user representation sessions
    if @current_representation_session&.user_representation? && !current_collective.is_main_collective?
      grant = @current_representation_session.trustee_grant
      unless grant&.allows_studio?(current_collective)
        flash[:alert] = "This studio is not included in your representation grant."
        redirect_to "/representing"
        return
      end
    end

    sm = current_collective.collective_members.find_by(user: @current_user)
    if sm.nil?
      if current_collective == current_tenant.main_collective
        if controller_name.ends_with?("sessions") || @current_user.collective_proxy?
          # Do nothing - sessions controller or collective proxy user doesn't need collective membership on main
        else
          current_collective.add_user!(@current_user)
        end
      elsif current_collective.accessible_by?(@current_user)
        # Collective proxy user accessing their own collective
        # No membership record needed, but access is allowed
      else
        # If this user has an invite to this collective, they will see the option to accept on the collective's join page.
        # Otherwise, they will see the collective's default join page, which may or may not allow them to join.
        path = "#{current_collective.path}/join"
        redirect_to path unless request.path == path
      end
    else
      # TODO: Add last_seen_at to CollectiveMember instead of touch
      sm.touch if controller_name != "sessions" && controller_name != "studios"
      @current_user.collective_member = sm
    end
  end

  def validate_unauthenticated_access
    return if @current_user || !@current_tenant.require_login? || is_auth_controller?

    if request.path.include?("/api/") || request.headers["Accept"] == "application/json"
      return render status: :unauthorized,
                    json: { error: "Unauthorized" }
    end

    if current_resource
      path = current_resource.path
      query_string = "?redirect_to_resource=#{path}"
    elsif params[:code] && controller_name == "studios"
      # Studio invite code
      query_string = "?code=#{params[:code]}"
    end
    redirect_to "/login" + (query_string || "")
  end

  def validate_scope
    return true if current_user && !current_token # Allow all actions for logged in users

    return if current_token.can?(request.method, current_resource_model)

    render json: { error: "You do not have permission to perform that action" }, status: :forbidden
  end

  # Clears the current representation session and related cookies.
  #
  # Cookie keys cleared:
  # - representation_session_id: The session ID
  # - representing_user: Handle of user being represented
  # - representing_studio: Handle of studio being represented
  def clear_representation!
    session.delete(:representation_session_id)
    session.delete(:representing_user)
    session.delete(:representing_studio)
    @current_user = @current_human_user
    @current_representation_session&.end!
    @current_representation_session = nil
  end

  attr_reader :current_human_user

  def current_representation_session
    return @current_representation_session if defined?(@current_representation_session)

    # For browser sessions, @current_representation_session is set by resolve_browser_representation
    # For API requests, it's set by resolve_api_representation
    # This method handles path validation for active sessions
    if @current_representation_session&.active?
      # Representation session should always be scoped to a studio or the /representing page.
      # The one exception is when ending representation via DELETE /u/:handle/represent.
      unless request.path.starts_with?("/representing") ||
             request.path.starts_with?("/studios/") ||
             request.path.starts_with?("/scenes/")
        ending_representation = request.path.ends_with?("/represent") && request.delete?
        unless ending_representation
          redirect_to "/representing"
        end
      end
    end
    @current_representation_session ||= nil
  end

  def current_heartbeat
    return @current_heartbeat if defined?(@current_heartbeat)

    @current_heartbeat = if current_user && !current_collective.is_main_collective?
                           Heartbeat.where(
                             tenant: current_tenant,
                             collective: current_collective,
                             user: current_user
                           ).where(
                             "created_at > ? and expires_at > ?", current_cycle.start_date, Time.current
                           ).first
                         end
  end

  def load_unread_notification_count
    return @unread_notification_count if defined?(@unread_notification_count)

    # Load notification count for HTML and markdown UI, but not JSON API
    @unread_notification_count = if @current_user && current_tenant && !request.format.json?
                                   NotificationService.unread_count_for(@current_user, tenant: current_tenant)
                                 else
                                   0
                                 end
  end

  CONTROLLERS_WITHOUT_RESOURCE_MODEL = ["home", "trio", "search", "two_factor_auth", "studios"].freeze

  def resource_model?
    return false if CONTROLLERS_WITHOUT_RESOURCE_MODEL.include?(controller_name)
    return false if controller_name.end_with?("sessions")

    true
  end

  def current_resource_model
    return @current_resource_model if defined?(@current_resource_model)

    @current_resource_model = resource_model? ? controller_name.classify.constantize : nil
  end

  def current_resource
    return @current_resource if defined?(@current_resource)
    return nil unless current_resource_model

    @current_resource = case current_resource_model.name
                        when "Decision"
                          current_decision
                        when "Commitment"
                          current_commitment
                        when "Note"
                          current_note
                        end
    @current_resource
  end

  def current_decision
    return @current_decision if defined?(@current_decision)

    decision_id = if current_resource_model == Decision
                    params[:id] || params[:decision_id]
                  else
                    params[:decision_id]
                  end
    return @current_decision = nil unless decision_id

    @current_decision = Decision.find(decision_id)
  end

  def current_decision_participant
    return @current_decision_participant if defined?(@current_decision_participant)

    if current_resource_model == DecisionParticipant
      @current_decision_participant = current_resource
    elsif current_decision && current_user
      @current_decision_participant = DecisionParticipantManager.new(
        decision: current_decision,
        user: current_user,
      ).find_or_create_participant
    else
      @current_decision_participant = nil
    end
    @current_decision_participant
  end

  def current_votes
    return @current_votes if defined?(@current_votes)

    @current_votes = (current_decision_participant.votes if current_decision_participant)
  end

  def current_commitment
    return @current_commitment if defined?(@current_commitment)

    commitment_id = if current_resource_model == Commitment
                      params[:id] || params[:commitment_id]
                    else
                      params[:commitment_id]
                    end
    return @current_commitment = nil unless commitment_id

    @current_commitment = Commitment.find(commitment_id)
  end

  def current_commitment_participant
    return @current_commitment_participant if defined?(@current_commitment_participant)

    if current_resource_model == CommitmentParticipant
      @current_commitment_participant = current_resource
    elsif current_commitment && current_user
      @current_commitment_participant = CommitmentParticipantManager.new(
        commitment: current_commitment,
        user: current_user,
      ).find_or_create_participant
    else
      @current_commitment_participant = nil
    end
    @current_commitment_participant
  end

  def current_note
    return @current_note if defined?(@current_note)

    note_id = if current_resource_model == Note
                params[:id] || params[:note_id]
              else
                params[:note_id]
              end
    return @current_note = nil unless note_id

    @current_note = Note.find(note_id)
  end

  def current_cycle
    return @current_cycle if defined?(@current_cycle)

    @current_cycle = Cycle.new_from_tempo(tenant: current_tenant, collective: current_collective)
  end

  def previous_cycle
    return @previous_cycle if defined?(@previous_cycle)

    @previous_cycle = Cycle.new(name: current_cycle.previous_cycle, tenant: current_tenant, collective: current_collective)
  end

  def metric
    render json: {
      metric_title: current_resource.metric_title,
      metric_value: current_resource.metric_value,
    }
  end

  def duration_param
    duration = model_params[:duration].to_i
    duration_unit = model_params[:duration_unit] || "hour(s)"
    case duration_unit
    when "minute(s)"
      duration.minutes
    when "hour(s)"
      duration.hours
    when "day(s)"
      duration.days
    when "week(s)"
      duration.weeks
    when "month(s)"
      duration.months
    when "year(s)"
      duration.years
    else
      raise "Unknown duration_unit: #{duration_unit}"
    end
  end

  def model_params
    return params unless current_resource_model
    params[current_resource_model.name.underscore.to_sym] || params
  end

  def deadline_from_params
    deadline_option = params[:deadline_option]
    if ["no_deadline", "close_at_critical_mass"].include?(deadline_option)
      100.years.from_now
    elsif deadline_option == "datetime" && params[:deadline]
      utc_deadline_param = @current_collective.timezone.parse(params[:deadline]).utc
      [utc_deadline_param, Time.current].max
    elsif deadline_option == "close_now"
      Time.current
    end
  end

  def reset_session
    clear_participant_uid_cookie
    super
  end

  def clear_participant_uid_cookie
    cookies.delete(:decision_participant_uid)
  end

  def encryptor
    @encryptor ||= begin
      key = Rails.application.secret_key_base
      raise "SECRET_KEY_BASE must be at least 32 characters" if key.nil? || key.length < 32

      derived_key = ActiveSupport::KeyGenerator.new(key).generate_key("cross_subdomain_token", 32)
      ActiveSupport::MessageEncryptor.new(derived_key)
    end
  end

  def encrypt(data)
    encryptor.encrypt_and_sign(data.to_json)
  end

  def decrypt(data)
    JSON.parse(encryptor.decrypt_and_verify(data))
  end

  def auth_subdomain
    ENV.fetch("AUTH_SUBDOMAIN", nil)
  end

  def auth_domain_login_url
    "https://#{auth_subdomain}.#{ENV.fetch("HOSTNAME", nil)}/login"
  end

  def pin
    @pinnable = current_resource
    return render "404", status: :not_found unless @pinnable

    if params[:pinned] == true
      @pinnable.pin!(tenant: @current_tenant, collective: @current_collective, user: @current_user)
    elsif params[:pinned] == false
      @pinnable.unpin!(tenant: @current_tenant, collective: @current_collective, user: @current_user)
    else
      raise "pinned param required. must be boolean value"
    end
    set_pin_vars
    render json: {
      pinned: @is_pinned,
      click_title: @pin_click_title,
    }
  end

  def set_pin_vars
    @pinnable = current_resource
    pin_destination = current_collective == current_tenant.main_collective ? "your profile" : "the studio homepage"
    @is_pinned = current_resource.is_pinned?(tenant: @current_tenant, collective: @current_collective, user: @current_user)
    @pin_click_title = "Click to " + (@is_pinned ? "unpin from " : "pin to ") + pin_destination
  end

  def api_helper(params: nil)
    # If params are provided, create a new instance with those params
    # Otherwise, use the memoized instance with controller params
    if params
      ApiHelper.new(
        current_user: current_user,
        current_collective: current_collective,
        current_tenant: current_tenant,
        current_representation_session: current_representation_session,
        current_cycle: current_cycle,
        current_heartbeat: current_heartbeat,
        current_resource_model: current_resource_model,
        current_resource: current_resource,
        current_note: current_note,
        current_decision: current_decision,
        current_decision_participant: current_decision_participant,
        current_commitment: current_commitment,
        current_commitment_participant: current_commitment_participant,
        model_params: params,
        params: params,
        request: request
      )
    else
      @api_helper ||= ApiHelper.new(
        current_user: current_user,
        current_collective: current_collective,
        current_tenant: current_tenant,
        current_representation_session: current_representation_session,
        current_cycle: current_cycle,
        current_heartbeat: current_heartbeat,
        current_resource_model: current_resource_model,
        current_resource: current_resource,
        current_note: current_note,
        current_decision: current_decision,
        current_decision_participant: current_decision_participant,
        current_commitment: current_commitment,
        current_commitment_participant: current_commitment_participant,
        model_params: model_params,
        params: self.params,
        request: request
      )
    end
  end

  def create_comment
    if current_resource.is_commentable?
      comment = api_helper.create_note(commentable: current_resource)

      respond_to do |format|
        format.html { redirect_to comment.path }
        format.json { render json: { success: true, comment_id: comment.truncated_id } }
      end
    else
      render status: :method_not_allowed, json: { message: "comments cannot be added to this datatype" }
    end
  end

  def comments_partial
    render partial: "shared/pulse_comments_list",
           locals: { commentable: current_resource },
           layout: false
  end

  def describe_add_comment
    render_action_description(ActionsHelper.action_description("add_comment", resource: current_resource))
  end

  def add_comment
    return render_action_error({ action_name: "add_comment", resource: current_resource, error: "You must be logged in." }) unless current_user

    unless current_resource&.is_commentable?
      return render_action_error({ action_name: "add_comment", resource: current_resource,
                                   error: "Comments cannot be added to this item.", })
    end

    begin
      api_helper.create_note(commentable: current_resource)
      render_action_success({
                              action_name: "add_comment",
                              resource: current_resource,
                              result: "Comment added successfully.",
                            })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
                            action_name: "add_comment",
                            resource: current_resource,
                            error: e.message,
                          })
    end
  end

  def render_actions_index(locals)
    @page_title ||= "Actions"
    base_path = request.path.split("/actions")[0]
    render "shared/actions_index", locals: {
      base_path: base_path,
      actions: locals[:actions], # { name: 'action_name', params_string: '(param1, param2)', description: 'description' }
    }
  end

  def actions_index_default
    raise NotImplementedError, "actions index must be implemented in child classes" if current_collective.is_main_collective?

    # This should be overridden in child classes.

    @page_title = "Actions | #{current_collective.name}"
    render "shared/actions_index_studio", locals: {
      base_path: request.path.split("/actions")[0],
    }
  end

  def render_action_description(locals)
    @page_title ||= "Action: #{locals[:action_name]}"
    render "shared/action_description", locals: {
      action_name: locals[:action_name],
      resource: locals[:resource],
      description: locals[:description],
      params: locals[:params], # { name: 'param_name', type: 'string', description: 'description' }
    }
  end

  def render_action_success(locals)
    @page_title ||= "Action Success: #{locals[:action_name]}"
    render "shared/action_success", locals: {
      action_name: locals[:action_name],
      resource: locals[:resource],
      result: locals[:result],
    }
  end

  def render_action_error(locals)
    @page_title ||= "Action Error: #{locals[:action_name]}"
    render "shared/action_error", locals: {
      action_name: locals[:action_name],
      resource: locals[:resource],
      error: locals[:error],
    }
  end

  def is_auth_controller?
    false
  end

  def check_session_timeout
    return if is_auth_controller?
    return unless session[:user_id].present?

    # Absolute timeout: session expires after fixed time from login (default 24 hours)
    if session[:logged_in_at].present? && Time.at(session[:logged_in_at]) < SESSION_ABSOLUTE_TIMEOUT.ago
      SecurityAuditLog.log_logout(user: current_human_user, ip: request.remote_ip, reason: "session_absolute_timeout") if current_human_user
      reset_session
      flash[:alert] = "Your session has expired. Please log in again."
      redirect_to "/login"
      return
    end

    # Idle timeout: session expires after inactivity (default 2 hours)
    if session[:last_activity_at].present? && Time.at(session[:last_activity_at]) < SESSION_IDLE_TIMEOUT.ago
      SecurityAuditLog.log_logout(user: current_human_user, ip: request.remote_ip, reason: "session_idle_timeout") if current_human_user
      reset_session
      flash[:alert] = "Your session has expired due to inactivity. Please log in again."
      redirect_to "/login"
      return
    end

    # Update last activity timestamp
    session[:last_activity_at] = Time.current.to_i
  end

  def check_user_suspension
    return if is_auth_controller?
    return unless session[:user_id].present?

    user = User.find_by(id: session[:user_id])
    return unless user&.suspended?

    SecurityAuditLog.log_suspended_login_attempt(user: user, ip: request.remote_ip)
    reset_session
    flash[:alert] = "Your account has been suspended."
    redirect_to "/login"
  end

  # Set Sentry context for error tracking
  def set_sentry_context
    return unless defined?(Sentry) && Sentry.initialized?

    Sentry.set_user(
      id: @current_user&.id,
      email: @current_user&.email,
      username: @current_user&.name,
      ip_address: request.remote_ip
    )

    Sentry.set_tags(
      tenant_id: @current_tenant&.id,
      collective_id: @current_collective&.id,
      subdomain: request.subdomain
    )

    Sentry.set_extras(
      user_type: @current_user&.user_type,
      api_request: api_token_present?
    )
  end
end
