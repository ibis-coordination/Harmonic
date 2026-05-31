# typed: false

class ApplicationController < ActionController::Base
  include ParsesScheduledTime
  include RateLimits
  # Session timeout configuration (in seconds)
  SESSION_ABSOLUTE_TIMEOUT = (ENV["SESSION_ABSOLUTE_TIMEOUT"]&.to_i || 24.hours).seconds
  SESSION_IDLE_TIMEOUT = (ENV["SESSION_IDLE_TIMEOUT"]&.to_i || 2.hours).seconds

  before_action :check_auth_subdomain, :current_app, :current_tenant, :current_collective,
                :current_path, :current_user, :current_resource, :current_representation_session, :current_heartbeat,
                :load_unread_notification_count, :set_sentry_context
  before_action :check_session_timeout
  before_action :check_user_suspension
  before_action :check_activation_gate
  before_action :check_stripe_billing_gate
  before_action :check_collective_archived

  # Default-noindex on every response except anon-readable HTML show actions on
  # tenants in ANON_READABLE_TENANT_SUBDOMAINS. prepend_around_action puts this
  # at the START of the callback chain so it wraps the auth before_actions —
  # the ensure block then runs even when the auth gate short-circuits with a
  # redirect. (after_action would be skipped on halt; a plain around_action
  # registered here would wrap nothing because there are no later callbacks.)
  prepend_around_action :set_robots_header

  # Include ActionCapabilityCheck AFTER before_action declarations so that
  # append_before_action puts check_capability_for_action at the END of the chain,
  # after current_user is set
  include ActionCapabilityCheck

  skip_before_action :verify_authenticity_token, if: :api_token_present?

  # Declares which actions of THIS controller are reachable without a logged-in
  # user, when the request matches the other 5 bypass conditions (anon-readable
  # tenant, main collective, GET/HEAD, HTML/Markdown, anonymous_main_collective_read_allowed?).
  #
  # Deliberately per-class via a class instance variable rather than
  # `class_attribute` — subclasses must NOT inherit declarations. Otherwise
  # `Api::V1::NotesController < NotesController` would silently inherit anon
  # access from its parent.
  def self.allows_anonymous(*actions)
    @anonymous_actions ||= Set.new
    @anonymous_actions.merge(actions.map(&:to_sym))
  end

  def self.allows_anonymous?(action)
    return false unless @anonymous_actions

    @anonymous_actions.include?(action.to_sym)
  end

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

  # Query params preserved in the canonical `current_path` (used in the
  # markdown frontmatter `path:`). Add params here when they carry meaning
  # the agent needs to see — search queries, comment highlights, pagination
  # cursors, time-range filters. Anything not listed is dropped so the
  # frontmatter URL stays clean and predictable.
  PRESERVED_QUERY_PARAMS = [
    "q",
    "comment_id",
    "cycle",
    "cursor",
    "offset",
    "status",
    "before",
    "after",
  ].freeze

  def current_path
    return @current_path if defined?(@current_path) && @current_path

    preserved = PRESERVED_QUERY_PARAMS.each_with_object({}) do |key, h|
      val = params[key]
      h[key] = val.to_s if val.present?
    end

    @current_path = preserved.any? ? "#{request.path}?#{preserved.to_query}" : request.path
  end

  def api_token_present?
    request.headers["Authorization"].present?
  end

  def current_token
    return @current_token if defined?(@current_token)
    return @current_token = nil unless api_token_present?

    prefix, token_string = request.headers["Authorization"].split
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
      collective_or_tenant = current_tenant.api_enabled? ? "collective" : "tenant"
      return render json: { error: "API not enabled for this #{collective_or_tenant}" }, status: :forbidden
    end
    return render json: { error: "API only supports JSON or Markdown formats" }, status: :forbidden unless json_or_markdown_request?

    # Bill humans-with-tokens at the same $3/mo as agents. Internal tokens and
    # ai_agent-owned tokens are exempt — agents are billed via their parent's
    # subscription, enforced at agent creation (pending pattern).
    if current_token && !current_token.internal? &&
       current_token.user.human? &&
       current_token.user.requires_stripe_billing?(current_tenant)
      return render json: {
        error: "billing_required",
        message: "Your API token is inactive. Set up billing at #{billing_show_url} to activate it.",
      }, status: :forbidden
    end

    # Activation gate for API tokens. For human-owned tokens, the user must be
    # fully activated. For agent-owned tokens, the agent's PARENT human must
    # be activated — otherwise a half-activated user could spawn an agent and
    # use the agent's token to bypass the gate. Internal (runner) tokens are
    # exempt; they're issued only for already-active agents.
    if current_token && !current_token.internal?
      token_human = current_token.user.human? ? current_token.user : current_token.user.parent
      if token_human&.human? && !token_human.fully_activated_for?(current_tenant)
        return render json: {
          error: "activation_required",
          message: "Your account isn't fully activated. Visit /activate in the browser to finish setup.",
        }, status: :forbidden
      end
    end

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
  # - API: via X-Representation-Session-ID + X-Representing-User/Collective headers
  # - Browser: via representation_session_id + representing_user/collective cookies
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
    # If api_authorize! already rendered an error (e.g., billing_required,
    # activation_required, API-not-enabled), short-circuit so downstream
    # representation handling doesn't try to render a second response.
    return nil if performed?

    # NOTE: must set @current_user before calling validate_scope to avoid infinite loop
    user = @current_token&.user
    return nil if user.nil?

    # Set @current_user temporarily for validate_scope (which calls current_user)
    @current_user = user
    validate_scope
    return nil if performed?

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
  # - Collective representation: X-Representing-Collective header with collective's handle
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

  # Validates the X-Representing-User or X-Representing-Collective header based on session type.
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

      if representing_user_header.blank?
        render json: { error: "X-Representing-User header required for user representation" }, status: :forbidden
        return false
      end

      unless representing_user_header == expected_handle
        render json: { error: "X-Representing-User header does not match the represented user" }, status: :forbidden
        return false
      end
    else
      # Collective representation requires X-Representing-Collective header
      representing_collective_header = request.headers["X-Representing-Collective"]
      expected_handle = session.collective&.handle

      if representing_collective_header.blank?
        render json: { error: "X-Representing-Collective header required for collective representation" }, status: :forbidden
        return false
      end

      unless representing_collective_header == expected_handle
        render json: { error: "X-Representing-Collective header does not match the represented collective" }, status: :forbidden
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
    # DELETE /collectives/:handle/represent - end collective representation
    # DELETE /collectives/:handle/r/:id - end specific session
    request.path == "/representing" ||
      request.path.match?(%r{^/collectives/[^/]+/represent$}) ||
      request.path.match?(%r{^/collectives/[^/]+/r/[^/]+$})
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
  # - representing_collective: handle of the collective being represented
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
  # - Validates representing_user/collective cookie matches session target
  # - Sets @current_user to the trustee user if valid
  def resolve_browser_representation
    return if session[:representation_session_id].blank?
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

  # Validates the representing_user or representing_collective cookie matches the session.
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
      # Collective representation requires representing_collective cookie
      representing_collective = session[:representing_collective]
      expected_handle = rep_session.collective&.handle
      representing_collective.present? && representing_collective == expected_handle
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

    # The cookie set during the cross-subdomain OAuth round-trip is
    # `:collective_invite_code` (see SessionsController#redirect_to_auth_domain).
    # We tolerate both names so a direct ?code= URL navigation also works.
    code = params[:code] || cookies[:collective_invite_code] || cookies[:invite_code]
    @current_invite = (Invite.find_by(collective: current_collective, code: code) if code.present?)
    @current_invite
  end

  def validate_authenticated_access
    tu = @current_tenant.tenant_users.find_by(user: @current_user)
    if tu.nil?
      accepting_invite = current_invite && current_invite.collective == @current_collective
      # Any auth-flow controller (sessions, signup, activation, email
      # confirmations, reverification, etc.) bypasses the membership gate.
      # Activation specifically needs this so a user can reach /activate via
      # an invite cookie before they've accepted (and become a member).
      gate_controller = is_auth_controller?
      if !@current_tenant.require_invite? && @current_tenant.require_login? && !gate_controller
        @current_tenant.add_user!(@current_user)
      elsif @current_tenant.require_login? && !gate_controller && !accepting_invite
        redirect_to "/invite-required"
        return # CRITICAL: must return after redirect — otherwise execution
        # falls through to the collective_members.add_user! branch below and
        # creates a spurious main-collective membership for non-tenant-members.
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

    # Check grant collective scope for user representation sessions
    if @current_representation_session&.user_representation? && !current_collective.is_main_collective?
      # Private workspaces are never accessible during representation
      if current_collective.private_workspace?
        flash[:alert] = "Private workspaces cannot be accessed during representation."
        redirect_to "/representing"
        return
      end

      grant = @current_representation_session.trustee_grant
      unless grant&.allows_collective?(current_collective)
        flash[:alert] = "This collective is not included in your representation grant."
        redirect_to "/representing"
        return
      end
    end

    sm = current_collective.collective_members.find_by(user: @current_user)
    if sm.nil?
      if current_collective == current_tenant.main_collective
        if controller_name.ends_with?("sessions") || @current_user.collective_identity?
          # Do nothing - sessions controller or collective identity user doesn't need collective membership on main
        else
          current_collective.add_user!(@current_user)
        end
      elsif current_collective.accessible_by?(@current_user)
        # Collective identity user accessing their own collective
        # No membership record needed, but access is allowed
      else
        # If this user has an invite to this collective, they will see the option to accept on the collective's join page.
        # Otherwise, they will see the collective's default join page, which may or may not allow them to join.
        path = "#{current_collective.path}/join"
        redirect_to path unless request.path == path
      end
    else
      # TODO: Add last_seen_at to CollectiveMember instead of touch
      sm.touch if controller_name != "sessions" && controller_name != "collectives"
      @current_user.collective_member = sm
    end
  end

  def validate_unauthenticated_access
    return if @current_user || !@current_tenant.require_login? || is_auth_controller?
    return if token_authenticated_action?
    return if anonymous_main_collective_read_allowed?

    if request.path.include?("/api/") || request.headers["Accept"] == "application/json"
      return render status: :unauthorized,
                    json: { error: "Unauthorized" }
    end

    if current_resource
      path = current_resource.path
      query_string = "?redirect_to_resource=#{path}"
    elsif params[:code] && controller_name == "collectives"
      # Collective invite code
      query_string = "?code=#{params[:code]}"
    end
    redirect_to "/login#{query_string || ""}"
  end

  # All 6 conditions for anonymous read access to the main collective. Any
  # missed condition fails closed (returns false → request continues to the
  # /login redirect below).
  def anonymous_main_collective_read_allowed?
    @current_user.nil? &&
      @current_tenant&.public_main_collective? &&
      @current_collective&.is_main_collective? &&
      (request.get? || request.head?) &&
      self.class.allows_anonymous?(action_name) &&
      anonymous_format_allowed?
  end

  # Anon-allowed response formats: HTML, Markdown, and `*/*` (Mime::ALL,
  # the default for curl, monitoring tools, and the wildcard tail of every
  # real browser's Accept header). `*/*` is safe because the anon-allowed
  # controllers either declare `respond_to` with html/md only or rely on
  # template-based default rendering, both of which resolve `*/*` to HTML.
  # JSON/XML/CSV/etc. are denied.
  def anonymous_format_allowed?
    fmt = request.format
    fmt == Mime::ALL || [:html, :md].include?(fmt.symbol)
  end

  # Per-action header to prevent cross-audience cache reuse: anon and
  # logged-in users hit the same URL and see different content, so no
  # shared cache (proxy, CDN, browser back-button) can safely reuse a
  # response. Applied to BOTH user states on allowlisted actions.
  # Note: Rails normalizes away `must-revalidate` when `no-store` is set
  # (it's redundant — nothing was stored to revalidate).
  def set_no_cache_headers
    response.headers["Cache-Control"] = "private, no-store"
  end

  # Per-IP rate limit for the three anon-readable show actions. No-op for
  # logged-in users (they have per-user limits elsewhere). 429 with
  # Retry-After when exceeded.
  ANONYMOUS_READ_RATE_LIMIT = 60
  ANONYMOUS_READ_RATE_PERIOD = 1.minute

  def enforce_anonymous_read_rate_limit
    return if @current_user

    enforce_rate_limit!(
      scope: "anon_read",
      key: request.remote_ip,
      limit: ANONYMOUS_READ_RATE_LIMIT,
      period: ANONYMOUS_READ_RATE_PERIOD,
    )
  rescue RateLimits::Exceeded
    SecurityAuditLog.log_rate_limited(
      ip: request.remote_ip,
      matched: "anon_read",
      request_path: request.path,
    )
    response.headers["Retry-After"] = ANONYMOUS_READ_RATE_PERIOD.to_i.to_s
    render plain: "Too many requests. Try again in a moment.", status: :too_many_requests
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
  # - representing_collective: Handle of collective being represented
  def clear_representation!
    session.delete(:representation_session_id)
    session.delete(:representing_user)
    session.delete(:representing_collective)
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
    # Representation session should always be scoped to a collective or the /representing page.
    # The one exception is when ending representation via DELETE /u/:handle/represent.
    if @current_representation_session&.active? && !(request.path.starts_with?("/representing") ||
                 request.path.starts_with?("/collectives/"))
      ending_representation = request.path.ends_with?("/represent") && request.delete?
      redirect_to "/representing" unless ending_representation
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

  def blocked_user_ids
    return @blocked_user_ids if defined?(@blocked_user_ids)

    @blocked_user_ids = if @current_user
                          Set.new(UserBlock.where(blocker: @current_user).pluck(:blocked_id))
                        else
                          Set.new
                        end
  end
  helper_method :blocked_user_ids

  # Bidirectional: all user IDs involved in a block with the current user (either direction).
  # Used by feed items which are hidden in both directions.
  def block_related_user_ids
    return @block_related_user_ids if defined?(@block_related_user_ids)

    @block_related_user_ids = if @current_user
                                ids = UserBlock
                                  .where("blocker_id = :uid OR blocked_id = :uid", uid: @current_user.id)
                                  .pluck(:blocker_id, :blocked_id)
                                  .flatten - [@current_user.id]
                                Set.new(ids)
                              else
                                Set.new
                              end
  end
  helper_method :block_related_user_ids

  # True only for anon viewer + public main collective tenant + allows_anonymous
  # action + HTML format. Single source of truth for both the X-Robots-Tag
  # header (set in the after_action) and the OG/Twitter meta block (emitted in
  # the shared/_meta_tags partial). Markdown and logged-in HTML responses are
  # intentionally non-indexable because their rendered content differs from
  # what we want crawlers to see.
  def anon_readable_indexable_response?
    @current_user.nil? &&
      @current_tenant&.public_main_collective? &&
      self.class.allows_anonymous?(action_name.to_sym) &&
      indexable_html_format?
  end
  helper_method :anon_readable_indexable_response?

  # HTML or `*/*` (Mime::ALL, the default for curl, link unfurlers, monitors,
  # and the wildcard tail of every real browser's Accept header — all of which
  # actually receive HTML). Markdown / JSON / XML / CSV are excluded — the
  # markdown surface in particular is for AI agents, not crawlers.
  def indexable_html_format?
    fmt = request.format
    fmt == Mime::ALL || fmt.html?
  end

  # Canonical scheme + host for the current tenant. Used for OG image and
  # canonical URLs so unfurlers and crawlers get the public hostname. Built
  # from request.protocol (which honors X-Forwarded-Proto from the TLS-
  # terminating proxy) and the configured HOSTNAME + tenant subdomain.
  # Deliberately NOT request.host_with_port — host_with_port can carry an
  # internal upstream port when behind a reverse proxy/CDN. Safe to call
  # only when @current_tenant is present (the meta partial gates it behind
  # anon_readable_indexable_response?).
  def canonical_base_url
    "#{request.protocol}#{@current_tenant.subdomain}.#{ENV.fetch('HOSTNAME', nil)}"
  end
  helper_method :canonical_base_url

  def set_robots_header
    yield
  ensure
    response.set_header("X-Robots-Tag", "noindex, nofollow") unless anon_readable_indexable_response?
  end

  # First non-heading paragraph of `text`, whitespace-collapsed, truncated at
  # a word boundary with a … suffix. Used to populate @page_description /
  # @page_title for OG/Twitter meta tags on anon-readable show pages.
  # Markdown is not stripped — most markdown reads fine in unfurl previews,
  # and a regex-based stripper is more risk than reward.
  def excerpt(text, max:)
    return nil if text.blank?

    body = text.to_s.split(/\n\s*\n/).map(&:strip).reject(&:blank?).find { |p| !p.start_with?("#") }
    body && body.gsub(/\s+/, " ").truncate(max, separator: " ", omission: "…")
  end

  # Ivar name must match readers in app/views/layouts/application.md.erb and
  # _top_right_menu.html.erb — do not rename to match the method name.
  # rubocop:disable Naming/MemoizedInstanceVariableName
  def load_unread_notification_count
    return @unread_notification_count if defined?(@unread_notification_count)

    # Load notification count for HTML and markdown UI, but not JSON API.
    @unread_notification_count = if @current_user && current_tenant && !request.format.json?
                                   NotificationService.unread_count_for(@current_user, tenant: current_tenant)
                                 else
                                   0
                                 end
  end
  # rubocop:enable Naming/MemoizedInstanceVariableName

  CONTROLLERS_WITHOUT_RESOURCE_MODEL = ["home", "trio", "search", "two_factor_auth", "reverification", "collectives", "help",
                                        "collective_data_transfers", "user_data_exports", "signup", "activation", "email_confirmations", "direct_uploads",
                                        "application",].freeze

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

    @current_decision = begin
      Decision.find(decision_id)
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  def current_decision_participant
    return @current_decision_participant if defined?(@current_decision_participant)

    @current_decision_participant = if current_resource_model == DecisionParticipant
                                      current_resource
                                    elsif current_decision && current_user
                                      DecisionParticipantManager.new(
                                        decision: current_decision,
                                        user: current_user
                                      ).find_or_create_participant
                                    end
    @current_decision_participant
  end

  def current_votes
    return @current_votes if defined?(@current_votes)

    @current_votes = current_decision_participant ? current_decision_participant.votes : Vote.none
  end

  def current_commitment
    return @current_commitment if defined?(@current_commitment)

    commitment_id = if current_resource_model == Commitment
                      params[:id] || params[:commitment_id]
                    else
                      params[:commitment_id]
                    end
    return @current_commitment = nil unless commitment_id

    @current_commitment = begin
      Commitment.find(commitment_id)
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  def current_commitment_participant
    return @current_commitment_participant if defined?(@current_commitment_participant)

    @current_commitment_participant = if current_resource_model == CommitmentParticipant
                                        current_resource
                                      elsif current_commitment && current_user
                                        CommitmentParticipantManager.new(
                                          commitment: current_commitment,
                                          user: current_user
                                        ).find_or_create_participant
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

    @current_note = begin
      Note.find(note_id)
    rescue ActiveRecord::RecordNotFound
      nil
    end
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
      utc_deadline = parse_scheduled_time(params[:deadline], timezone: params[:timezone])
      utc_deadline ? [utc_deadline, Time.current].max : nil
    elsif deadline_option == "close_now"
      Time.current
    end
  end

  def reset_session
    clear_participant_uid_cookie
    super
  end

  # Central logout method. Clears all session state, representation, and cross-subdomain cookies.
  # Use this instead of calling reset_session directly when logging a user out.
  def logout_user!
    clear_representation!
    reset_session
    delete_shared_domain_cookie(:token, path: "/login/callback")
    delete_shared_domain_cookie(:redirect_to_subdomain)
    delete_shared_domain_cookie(:redirect_to_resource)
    delete_shared_domain_cookie(:collective_invite_code)
  end

  def delete_shared_domain_cookie(key, path: nil)
    opts = { domain: ".#{ENV.fetch("HOSTNAME", nil)}" }
    opts[:path] = path if path
    cookies.delete(key, **opts)
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

  def set_report_vars(resource)
    @already_reported = current_user && ContentReport.exists?(reporter: current_user, reportable: resource)
  end

  def report_content_flash
    if params[:also_block] == "1"
      "Thank you for your report. The author has been blocked and our moderators will review the reported content."
    else
      "Thank you for reporting. Our moderators will review it."
    end
  end

  def set_pin_vars
    @pinnable = current_resource
    pin_destination = current_collective == current_tenant.main_collective ? "your profile" : "the collective homepage"
    # Pinning to "your profile" requires a user. Anon viewers on the main
    # collective have no profile to pin to, and the pin UI is hidden for them.
    if @current_user.nil?
      @is_pinned = false
      @pin_click_title = nil
      return
    end
    @is_pinned = current_resource.is_pinned?(tenant: @current_tenant, collective: @current_collective, user: @current_user)
    @pin_click_title = "Click to #{@is_pinned ? "unpin from " : "pin to "}#{pin_destination}"
  end

  def api_helper(params: nil)
    # If params are provided, create a new instance with those params
    # Otherwise, use the memoized instance with controller params
    if params
      ApiHelper.new(
        current_user: current_user,
        current_collective: current_collective,
        current_tenant: current_tenant,
        current_token: current_token,
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
        current_token: current_token,
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

  COMMENTS_PER_MINUTE = 5

  def create_comment
    if current_user && current_resource
      begin
        enforce_rate_limit!(
          scope: "comments",
          key: [current_user.id, current_resource.id],
          limit: COMMENTS_PER_MINUTE,
          period: 1.minute
        )
      rescue RateLimits::Exceeded
        respond_to do |format|
          format.html do
            flash[:alert] = "You're commenting too quickly. Please wait a moment and try again."
            redirect_back(fallback_location: current_resource.path)
          end
          format.json do
            render status: :too_many_requests, json: { error: "rate_limited", message: "Too many comments. Please wait a minute and try again." }
          end
        end
        return
      end
    end

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
    return render_action_error({ action_name: "add_comment", resource: current_resource, error: "You must be logged in.", status: :unauthorized }) unless current_user

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
    render "shared/actions_index_collective", locals: {
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

  # Action endpoint success response. For HTML (browser form submits), this
  # redirects with a flash message so Turbo Drive follows the redirect rather
  # than silently dropping a 200-with-HTML response. The md (markdown) action
  # API contract is unchanged: 200 with a structured body describing the
  # outcome.
  #
  # Callers may pass `redirect_to:` to override the HTML redirect target.
  # Otherwise the helper sends the user back to where they came from (referer
  # if safe-same-origin) or falls back to the resource's own page, then to
  # the site root.
  def render_action_success(locals)
    respond_to do |format|
      format.html do
        flash[:notice] = locals[:result].to_s if locals[:result].present?
        redirect_to_action_endpoint_target(locals[:redirect_to], locals[:resource])
      end
      format.md do
        @page_title ||= "Action Success: #{locals[:action_name]}"
        render "shared/action_success", locals: {
          action_name: locals[:action_name],
          resource: locals[:resource],
          result: locals[:result],
        }
      end
    end
  end

  # Action endpoint error response. HTML redirects back with a flash error so
  # Turbo follows the redirect. The md/json action API uses real HTTP status
  # codes so stateless clients (MCP server, agent-runner) can branch on
  # outcome without parsing the body. Default is 422 (unprocessable entity);
  # callers may pass `status:` to surface 401 (unauthenticated), 403
  # (forbidden), 404 (not found), or 409 (conflict) where appropriate.
  def render_action_error(locals)
    respond_to do |format|
      format.html do
        flash[:error] = locals[:error].to_s if locals[:error].present?
        redirect_to_action_endpoint_target(locals[:redirect_to], locals[:resource])
      end
      format.md do
        @page_title ||= "Action Error: #{locals[:action_name]}"
        render "shared/action_error", locals: {
          action_name: locals[:action_name],
          resource: locals[:resource],
          error: locals[:error],
        }, status: locals[:status] || :unprocessable_entity
      end
    end
  end

  # Issue the redirect for HTML action-endpoint responses. Uses
  # redirect_back_or_to so an unsafe / missing referer falls back cleanly to
  # the resource's page (then "/") instead of raising UnsafeRedirectError.
  def redirect_to_action_endpoint_target(explicit, resource)
    return redirect_to(explicit) if explicit.present?

    fallback = (resource.path if resource.respond_to?(:path) && resource.path.present?) || "/"
    redirect_back_or_to(fallback)
  end

  # Catch-all handler for POST/GET /{path}/actions/{unknown_name} when
  # {unknown_name} isn't an explicit describe_* / execute_* route. Returns
  # 404 whose body lists the actions defined at {path}, so a client can
  # recover from a typo or wrong-resource guess in one round trip. Wired up
  # at the bottom of config/routes.rb so explicit routes always win.
  def unknown_action_fallback
    url_prefix = "/#{params[:url_prefix]}"
    unknown_name = params[:unknown_name].to_s

    respond_to do |format|
      format.md do
        render template: "shared/unknown_action",
          locals: {
            url_prefix: url_prefix,
            unknown_name: unknown_name,
            available_actions: lookup_actions_for_prefix(url_prefix),
          },
          status: :not_found
      end
      format.any { head :not_found }
    end
  end

  # Resolve a request path back to the actions defined for the page it would
  # display. Returns [] when the path doesn't resolve or has no defined actions.
  # Some action entries (especially conditional_actions) only carry :name; we
  # fall back to ActionsHelper.action_definition for description/params_string
  # so the rendered list is never blank.
  def lookup_actions_for_prefix(url_prefix)
    recognized = Rails.application.routes.recognize_path(url_prefix, method: :get)
    controller_action = "#{recognized[:controller]}##{recognized[:action]}"
    route_pattern = ActionsHelper.route_pattern_for(controller_action)
    return [] unless route_pattern

    route_info = ActionsHelper.actions_for_route(route_pattern)
    return [] unless route_info

    raw = (route_info[:actions] || []) + (route_info[:conditional_actions] || [])
    raw.map do |action|
      definition = ActionsHelper.action_definition(action[:name])
      {
        name: action[:name],
        params_string: action[:params_string] || definition&.dig(:params_string) || "",
        description: action[:description] || definition&.dig(:description) || "",
      }
    end
  rescue ActionController::RoutingError
    []
  end

  def is_auth_controller?
    false
  end

  # Override in controllers that have actions authenticated by a URL token
  # instead of a session (e.g., email confirmation, password reset).
  # These actions are exempt from the login requirement.
  def token_authenticated_action?
    false
  end

  def check_session_timeout
    return if is_auth_controller?
    return if session[:user_id].blank?

    # Absolute timeout: session expires after fixed time from login (default 24 hours)
    if session[:logged_in_at].present? && Time.zone.at(session[:logged_in_at]) < SESSION_ABSOLUTE_TIMEOUT.ago
      SecurityAuditLog.log_logout(user: current_human_user, ip: request.remote_ip, reason: "session_absolute_timeout") if current_human_user
      logout_user!
      flash[:alert] = "Your session has expired. Please log in again."
      redirect_to "/login"
      return
    end

    # Session revocation: admin has revoked all sessions for this user
    if session[:logged_in_at].present? && current_human_user&.sessions_revoked_at.present? && Time.zone.at(session[:logged_in_at]) < (current_human_user.sessions_revoked_at)
      SecurityAuditLog.log_logout(user: current_human_user, ip: request.remote_ip, reason: "sessions_revoked")
      logout_user!
      flash[:alert] = "Your session has been revoked. Please log in again."
      redirect_to "/login"
      return
    end

    # Idle timeout: session expires after inactivity (default 2 hours)
    if session[:last_activity_at].present? && Time.zone.at(session[:last_activity_at]) < SESSION_IDLE_TIMEOUT.ago
      SecurityAuditLog.log_logout(user: current_human_user, ip: request.remote_ip, reason: "session_idle_timeout") if current_human_user
      logout_user!
      flash[:alert] = "Your session has expired due to inactivity. Please log in again."
      redirect_to "/login"
      return
    end

    # Update last activity timestamp
    session[:last_activity_at] = Time.current.to_i
  end

  def check_user_suspension
    return if is_auth_controller?
    return if session[:user_id].blank?

    user = User.find_by(id: session[:user_id])
    return unless user&.suspended?

    SecurityAuditLog.log_suspended_login_attempt(user: user, ip: request.remote_ip)
    logout_user!
    flash[:alert] = "Your account has been suspended."
    redirect_to "/login"
  end

  # Activation gate: before a human can use the app, they must (1) be a member
  # of the current tenant, (2) have a verified email (if the tenant requires
  # it), and (3) have 2FA enabled (if the tenant requires it). When any
  # requirement is missing the user is bounced to /activate, which walks them
  # through the missing pieces.
  #
  # Exempt: non-humans, sys/app admins, auth controllers (/activate itself,
  # signup, login, two_factor_auth, email_confirmations, etc.), API requests,
  # and the user-settings pages they may need to update profile/email/2FA.
  def check_activation_gate
    # Activation is a property of the actual signed-in human (the person at the
    # keyboard). Under representation, @current_user is the trustee identity
    # being acted as — that's not the user we want to gate on.
    human = @current_human_user || @current_user
    return unless human&.human?
    return if is_auth_controller?
    return if api_token_present?
    return if request.path.start_with?("/api/")
    # User-settings actions only (not `show`, which is the public profile page
    # and should be gated). Users need settings to manage their email + change
    # other identity fields linked from /activate.
    return if controller_name == "users" && action_name.in?(["settings", "update_profile", "update_email", "cancel_email_change", "confirm_email",
                                                             "update_image",])
    return if controller_name == "two_factor_auth"

    return if human.fully_activated_for?(@current_tenant)

    # Preserve where the user was headed so /activate can resume after
    # completion. Same HTML-GET filter as the billing gate to avoid clobbering
    # the real destination with background polls.
    session[:activation_return_to] = request.fullpath if request.get? && request.format.html? && !request.xhr?

    redirect_to "/activate"
  end

  # Billing gate: when stripe_billing is enabled, human users must have an active
  # subscription before they can use the app. Exempt: billing pages, auth routes,
  # webhooks, API controllers, non-human users, user settings.
  def check_stripe_billing_gate
    return unless @current_user&.human?
    return unless @current_tenant&.feature_enabled?("stripe_billing")
    return if @current_user.stripe_billing_setup?

    # Exempt controllers (webhooks and healthcheck inherit from ActionController::Base,
    # not ApplicationController, so they're inherently exempt)
    return if is_auth_controller?
    return if is_a?(BillingController)
    # ApiTokensController routes the user through its own Stripe Checkout
    # flow on create (and resumes via #finalize). Bouncing to /billing here
    # would prevent it from running.
    return if is_a?(ApiTokensController)
    return if request.path.start_with?("/api/")
    # API requests (any path) have their own billing check inside api_authorize!.
    # Without this, collective-scoped API paths like /collectives/X/api/v1/...
    # would be redirected to /billing instead of returning a clean 403 JSON.
    return if api_token_present?

    # Exempt user settings page
    return if controller_name == "users" && action_name.in?(["settings", "show", "update_profile", "update_email", "cancel_email_change",
                                                             "confirm_email",])

    # Preserve where the user was headed so BillingController can resume the
    # flow after Stripe Checkout completes, and explain the bounce so the
    # user understands why they were redirected mid-task. Only stash top-level
    # HTML navigations: POST/PATCH/DELETE bodies can't be replayed, and
    # JSON/XHR polls (e.g. /notifications/unread_count) would otherwise
    # clobber the real destination since they fire from the same page load.
    if request.get? && request.format.html? && !request.xhr?
      session[:billing_return_to] = request.fullpath
      flash[:notice] = "Set up billing to continue. We'll bring you back here when you're done."
    end

    redirect_to "/billing"
  end

  # Redirect all requests to the settings page when a collective is archived.
  # Exempt: settings page, reactivation, billing, auth, and webhook controllers
  # (which inherit from ActionController::Base, not ApplicationController).
  def check_collective_archived
    is_archived = @current_collective.respond_to?(:archived?) && @current_collective.archived?
    is_pending = @current_collective.respond_to?(:pending_billing_setup?) && @current_collective.pending_billing_setup?
    return unless is_archived || is_pending
    return if is_auth_controller?
    return if is_a?(BillingController)
    return if controller_name == "collectives" && action_name.in?(["settings", "unarchive"])

    msg = is_pending ? "This collective is pending billing setup." : "This collective is deactivated."
    respond_to do |format|
      format.json { render json: { error: msg }, status: :forbidden }
      format.md { render plain: "#{msg} Visit /billing to manage.", status: :forbidden }
      format.any { redirect_to "#{@current_collective.path}/settings" }
    end
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
