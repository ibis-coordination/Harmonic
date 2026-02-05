# typed: false

class ApplicationController < ActionController::Base
  # Session timeout configuration (in seconds)
  SESSION_ABSOLUTE_TIMEOUT = (ENV['SESSION_ABSOLUTE_TIMEOUT']&.to_i || 24.hours).seconds
  SESSION_IDLE_TIMEOUT = (ENV['SESSION_IDLE_TIMEOUT']&.to_i || 2.hours).seconds

  before_action :check_auth_subdomain, :current_app, :current_tenant, :current_superagent,
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
    if request.subdomain == auth_subdomain && !is_auth_controller?
      redirect_to '/login'
    end
  end

  def single_tenant_mode?
    ENV['SINGLE_TENANT_MODE'] == 'true'
  end

  def current_app
    # TODO Remove this method. Logic is not longer needed.
    # This method should be overridden in the app-specific controllers.
    return @current_app if defined?(@current_app)
    @current_app = 'decisive'
    @current_app_title = 'Harmonic'
    @current_app_description = 'social agency platform'
    @current_app
  end

  def current_tenant
    return @current_tenant if defined?(@current_tenant)
    current_superagent
    @current_tenant ||= @current_superagent.tenant
    redirect_to '/404' if @current_tenant.archived?
    @current_tenant
  end

  def current_superagent
    return @current_superagent if defined?(@current_superagent)
    # begin
      # Superagent.scope_thread_to_superagent sets the current superagent and tenant based on the subdomain and handle
      # and raises an error if the subdomain or handle is not found.
      # Default scope is configured in ApplicationRecord to scope all queries to
      # Tenant.current_tenant_id and Superagent.current_superagent_id
      # and automatically set tenant_id and superagent_id on any new records.
      @current_superagent = Superagent.scope_thread_to_superagent(
        subdomain: request.subdomain,
        handle: params[:superagent_handle]
      )
      @current_tenant = @current_superagent.tenant
      # Set these associations to avoid unnecessary reloading.
      @current_superagent.tenant = @current_tenant
      @current_tenant.main_superagent = @current_superagent if @current_tenant.main_superagent_id == @current_superagent.id
    # rescue
    #   raise ActionController::RoutingError.new('Not Found')
    # end
    @current_superagent
  end

  def current_path
    @current_path ||= request.path
  end

  def api_token_present?
    request.headers['Authorization'].present?
  end

  def current_token
    return @current_token if defined?(@current_token)
    return @current_token = nil unless api_token_present?
    prefix, token_string = request.headers['Authorization'].split(' ')
    @current_token = ApiToken.authenticate(token_string, tenant_id: current_tenant.id)
    return nil unless @current_token
    if prefix == 'Bearer' && @current_token&.active?
      @current_token.token_used!
    elsif prefix == 'Bearer' && @current_token&.expired? && !@current_token.deleted?
      render json: { error: 'Token expired' }, status: 401
    else
      render json: { error: 'Unauthorized' }, status: 401
    end
    @current_token
  end

  def api_authorize!
    # Internal tokens bypass API enabled checks - they are system-managed
    # and used for internal operations like agent runners
    unless current_token&.internal? || (current_superagent.api_enabled? && current_tenant.api_enabled?)
      superagent_or_tenant = current_tenant.api_enabled? ? 'studio' : 'tenant'
      return render json: { error: "API not enabled for this #{superagent_or_tenant}" }, status: 403
    end
    return render json: { error: 'API only supports JSON or Markdown formats' }, status: 403 unless json_or_markdown_request?
    request.format = :md unless request.format == :json
    current_token || render(json: { error: 'Unauthorized' }, status: 401)
  end

  def json_or_markdown_request?
    # API tokens can only access JSON and Markdown endpoints.
    request.headers['Accept'] == 'application/json' ||
    request.headers['Accept'] == 'text/markdown' ||
    request.headers['Content-Type'] == 'application/json' ||
    request.headers['Content-Type'] == 'text/markdown' ||
    request.path.starts_with?('/api/') # Allow all API endpoints
  end

  def current_user
    return @current_user if defined?(@current_user)
    if api_token_present?
      api_authorize!
      # Note: must set @current_user before calling validate_scope to avoid infinite loop
      @current_user = @current_token&.user
      return nil if @current_user.nil?
      validate_scope
      # How do we handle representation through the API?
      return @current_user
    end
    @current_person_user = User.find_by(id: session[:user_id], user_type: "person") if session[:user_id].present?
    @current_subagent_user = User.find_by(id: session[:subagent_user_id], user_type: "subagent") if session[:subagent_user_id].present?
    @current_trustee_user = User.find_by(id: session[:trustee_user_id], user_type: "trustee") if session[:trustee_user_id].present?
    if @current_subagent_user && @current_person_user&.can_impersonate?(@current_subagent_user)
      @current_user = @current_subagent_user
    elsif @current_subagent_user
      clear_impersonations_and_representations!
      @current_subagent_user = nil
      @current_user = @current_person_user
    else
      @current_user = @current_person_user
    end
    if @current_trustee_user && @current_user&.can_represent?(@current_trustee_user)
      @current_user = @current_trustee_user
    elsif @current_trustee_user
      clear_impersonations_and_representations!
      @current_trustee_user = nil
      @current_user = @current_person_user
    end
    @current_user ||= @current_person_user
    if @current_user
      validate_authenticated_access
    else
      validate_unauthenticated_access
    end
    @current_user
  end

  def current_invite
    return @current_invite if defined?(@current_invite)
    if params[:code] || cookies[:invite_code]
      @current_invite = Invite.find_by(
        superagent: current_superagent,
        code: params[:code] || cookies[:invite_code]
      )
    else
      @current_invite = nil
    end
    @current_invite
  end

  def validate_authenticated_access
    tu = @current_tenant.tenant_users.find_by(user: @current_user)
    if tu.nil?
      accepting_invite = current_invite && current_invite.superagent == @current_superagent
      if @current_tenant.require_login? && controller_name != 'sessions' && !accepting_invite
@sidebar_mode = 'none'
        render status: 403, layout: 'application', template: 'sessions/403_to_logout'
      elsif accepting_invite && current_invite.is_acceptable_by_user?(@current_user)
        # The user still has to click "accept" to accept the invite to the superagent,
        # but they need to access the tenant to do so.
        # Not sure how to handle the case where the user does not accept the invite.
        # Should we remove the tenant_user record somehow?
        # Should we require that all tenant users be a member of at least one (non-main) superagent?
        @current_tenant.add_user!(@current_user)
      end
    else
      # This assignment prevents unnecessary reloading.
      @current_user.tenant_user = tu
    end
    sm = current_superagent.superagent_members.find_by(user: @current_user)
    if sm.nil?
      if current_superagent == current_tenant.main_superagent
        if controller_name.ends_with?('sessions' || @current_user.trustee?)
          # Do nothing
        else
          current_superagent.add_user!(@current_user)
        end
      elsif current_user.trustee? && current_user.trustee_superagent == current_superagent
        # TODO - decide how to handle this case. Trustee is not a member of the superagent, but is the trustee.
      else
        # If this user has an invite to this superagent, they will see the option to accept on the superagent's join page.
        # Otherwise, they will see the superagent's default join page, which may or may not allow them to join.
        path = "#{current_superagent.path}/join"
        redirect_to path unless request.path == path
      end
    else
      # TODO Add last_seen_at to SuperagentMember instead of touch
      sm.touch if controller_name != 'sessions' && controller_name != 'studios'
      @current_user.superagent_member = sm
    end
  end

  def validate_unauthenticated_access
    return if @current_user || !@current_tenant.require_login? || is_auth_controller?
    return render status: 401, json: { error: 'Unauthorized' } if request.path.include?('/api/') || request.headers['Accept'] == 'application/json'
    if current_resource
      path = current_resource.path
      query_string = "?redirect_to_resource=#{path}"
    elsif params[:code] && controller_name == 'studios'
      # Studio invite code
      query_string = "?code=#{params[:code]}"
    end
    redirect_to '/login' + (query_string || '')
  end

  def validate_scope
    return true if current_user && !current_token # Allow all actions for logged in users
    unless current_token.can?(request.method, current_resource_model)
      render json: { error: 'You do not have permission to perform that action' }, status: 403
    end
  end

  def clear_impersonations_and_representations!
    session.delete(:subagent_user_id)
    session.delete(:representation_session_id)
    session.delete(:trustee_user_id)
    @current_user = @current_person_user
    @current_subagent_user = nil
    @current_representation_session&.end!
    @current_representation_session = nil
  end

  def current_person_user
    @current_person_user
  end

  def current_subagent_user
    @current_subagent_user
  end

  def current_representation_session
    return @current_representation_session if defined?(@current_representation_session)
    if session[:representation_session_id].present?
      # Unscoped: RepresentationSession may belong to a different superagent than current context.
      # Security: Validated by matching trustee_user, representative_user, superagent, and id.
      @current_representation_session = RepresentationSession.unscoped.find_by(
        trustee_user: @current_user,
        # Person can be impersonating a subagent user who is representing the superagent via a representation session, all simultaneously.
        representative_user: @current_subagent_user || @current_person_user,
        superagent: @current_user.trustee_superagent,
        id: session[:representation_session_id]
      )
      if @current_representation_session.nil?
        # TODO - not sure what to do here. What are the security concerns?
        clear_impersonations_and_representations!
        flash[:alert] = 'Representation session not found. Please try again.'
      elsif @current_representation_session.expired?
        clear_impersonations_and_representations!
        flash[:alert] = 'Representation session expired.'
      elsif !request.path.starts_with?('/representing') && !(request.path.starts_with?('/studios/') || request.path.starts_with?('/scenes/'))
        # Representation session should always be scoped to a studio or the /representing page.
        # The one edge case exception is when a person user is impersonating a subagent user and
        # is ending the impersonation before ending the representation session.
        # In this case, the representation session should be ended automatically.
        ending_impersonation = @current_subagent_user && request.path.ends_with?("/impersonate")
        if ending_impersonation
          # Allow request to proceed. UsersController#stop_impersonating will handle the end of the representation session.
        else
          redirect_to '/representing'
        end
      end
    end
    @current_representation_session ||= nil
  end

  def current_heartbeat
    return @current_heartbeat if defined?(@current_heartbeat)
    if current_user && !current_superagent.is_main_superagent?
      @current_heartbeat = Heartbeat.where(
        tenant: current_tenant,
        superagent: current_superagent,
        user: current_user
      ).where(
        'created_at > ? and expires_at > ?', current_cycle.start_date, Time.current
      ).first
    else
      @current_heartbeat = nil
    end
  end

  def load_unread_notification_count
    return @unread_notification_count if defined?(@unread_notification_count)
    # Load notification count for HTML and markdown UI, but not JSON API
    if @current_user && current_tenant && !request.format.json?
      @unread_notification_count = NotificationService.unread_count_for(@current_user, tenant: current_tenant)
    else
      @unread_notification_count = 0
    end
  end

  CONTROLLERS_WITHOUT_RESOURCE_MODEL = %w[home trio search two_factor_auth].freeze

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
    case current_resource_model.name
    when 'Decision'
      @current_resource = current_decision
    when 'Commitment'
      @current_resource = current_commitment
    when 'Note'
      @current_resource = current_note
    else
      @current_resource = nil
    end
    @current_resource
  end

  def current_decision
    return @current_decision if defined?(@current_decision)
    if current_resource_model == Decision
      decision_id = params[:id] || params[:decision_id]
    else
      decision_id = params[:decision_id]
    end
    return @current_decision = nil unless decision_id
    @current_decision = Decision.find(decision_id)
  end

  def current_decision_participant
    return @current_decision_participant if defined?(@current_decision_participant)
    if current_resource_model == DecisionParticipant
      @current_decision_participant = current_resource
    # elsif params[:decision_participant_id].present?
    #   @current_decision_participant = current_decision.participants.find_by(id: params[:decision_participant_id])
    # elsif params[:participant_id].present?
    #   @current_decision_participant = current_decision.participants.find_by(id: params[:participant_id])
    elsif current_decision
      @current_decision_participant = DecisionParticipantManager.new(
        decision: current_decision,
        user: current_user,
        participant_uid: cookies[:decision_participant_uid],
      ).find_or_create_participant
      unless current_user
        # Cookie is only needed if user is not logged in.
        cookies[:decision_participant_uid] = {
          value: @current_decision_participant.participant_uid,
          expires: 30.days.from_now,
          httponly: true,
        }
      end
    else
      @current_decision_participant = nil
    end
    @current_decision_participant
  end

  def current_votes
    return @current_votes if defined?(@current_votes)
    if current_decision_participant
      @current_votes = current_decision_participant.votes
    else
      @current_votes = nil
    end
  end

  def current_commitment
    return @current_commitment if defined?(@current_commitment)
    if current_resource_model == Commitment
      commitment_id = params[:id] || params[:commitment_id]
    else
      commitment_id = params[:commitment_id]
    end
    return @current_commitment = nil unless commitment_id
    @current_commitment = Commitment.find(commitment_id)
  end

  def current_commitment_participant
    return @current_commitment_participant if defined?(@current_commitment_participant)
    if current_resource_model == CommitmentParticipant
      @current_commitment_participant = current_resource
    elsif current_commitment
      @current_commitment_participant = CommitmentParticipantManager.new(
        commitment: current_commitment,
        user: current_user,
        participant_uid: cookies[:commitment_participant_uid],
      ).find_or_create_participant
      unless current_user
        # Cookie is only needed if user is not logged in.
        cookies[:commitment_participant_uid] = {
          value: @current_commitment_participant.participant_uid,
          expires: 30.days.from_now,
          httponly: true,
        }
      end
    else
      @current_commitment_participant = nil
    end
    @current_commitment_participant
  end

  def current_note
    return @current_note if defined?(@current_note)
    if current_resource_model == Note
      note_id = params[:id] || params[:note_id]
    else
      note_id = params[:note_id]
    end
    return @current_note = nil unless note_id
    @current_note = Note.find(note_id)
  end

  def current_cycle
    return @current_cycle if defined?(@current_cycle)
    @current_cycle = Cycle.new_from_tempo(tenant: current_tenant, superagent: current_superagent)
  end

  def previous_cycle
    return @previous_cycle if defined?(@previous_cycle)
    @previous_cycle = Cycle.new(name: current_cycle.previous_cycle, tenant: current_tenant, superagent: current_superagent)
  end

  def metric
    render json: {
      metric_title: current_resource.metric_title,
      metric_value: current_resource.metric_value,
    }
  end

  def duration_param
    duration = model_params[:duration].to_i
    duration_unit = model_params[:duration_unit] || 'hour(s)'
    case duration_unit
    when 'minute(s)'
      duration.minutes
    when 'hour(s)'
      duration.hours
    when 'day(s)'
      duration.days
    when 'week(s)'
      duration.weeks
    when 'month(s)'
      duration.months
    when 'year(s)'
      duration.years
    else
      raise "Unknown duration_unit: #{duration_unit}"
    end
  end

  def model_params
    params[current_resource_model.name.underscore.to_sym] || params
  end

  def deadline_from_params
    deadline_option = params[:deadline_option]
    if deadline_option == 'no_deadline' || deadline_option == 'close_at_critical_mass'
      return Time.current + 100.years
    elsif deadline_option == 'datetime' && params[:deadline]
      utc_deadline_param = @current_superagent.timezone.parse(params[:deadline]).utc
      return [utc_deadline_param, Time.current].max
    elsif deadline_option == 'close_now'
      return Time.current
    else
      return nil
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
    ENV['AUTH_SUBDOMAIN']
  end

  def auth_domain_login_url
    "https://#{auth_subdomain}.#{ENV['HOSTNAME']}/login"
  end

  def pin
    @pinnable = current_resource
    return render '404', status: 404 unless @pinnable
    if params[:pinned] == true
      @pinnable.pin!(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
    elsif params[:pinned] == false
      @pinnable.unpin!(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
    else
      raise 'pinned param required. must be boolean value'
    end
    set_pin_vars
    render json: {
      pinned: @is_pinned,
      click_title: @pin_click_title,
    }
  end

  def set_pin_vars
    @pinnable = current_resource
    pin_destination = current_superagent == current_tenant.main_superagent ? 'your profile' : 'the studio homepage'
    @is_pinned = current_resource.is_pinned?(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
    @pin_click_title = 'Click to ' + (@is_pinned ? 'unpin from ' : 'pin to ') + pin_destination
  end

  def api_helper
    @api_helper ||= ApiHelper.new(
      current_user: current_user,
      current_superagent: current_superagent,
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
      params: params,
      request: request
    )
  end

  def create_comment
    if current_resource.is_commentable?
      comment = api_helper.create_note(commentable: current_resource)

      respond_to do |format|
        format.html { redirect_to comment.path }
        format.json { render json: { success: true, comment_id: comment.truncated_id } }
      end
    else
      render status: 405, json: { message: "comments cannot be added to this datatype" }
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
    return render_action_error({ action_name: 'add_comment', resource: current_resource, error: 'You must be logged in.' }) unless current_user
    return render_action_error({ action_name: 'add_comment', resource: current_resource, error: 'Comments cannot be added to this item.' }) unless current_resource&.is_commentable?

    begin
      comment = api_helper.create_note(commentable: current_resource)
      render_action_success({
        action_name: 'add_comment',
        resource: current_resource,
        result: "Comment added successfully.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'add_comment',
        resource: current_resource,
        error: e.message,
      })
    end
  end

  def render_actions_index(locals)
    @page_title ||= "Actions"
    base_path = request.path.split('/actions')[0]
    render 'shared/actions_index', locals: {
      base_path: base_path,
      actions: locals[:actions], # { name: 'action_name', params_string: '(param1, param2)', description: 'description' }
    }
  end

  def actions_index_default
    if current_superagent.is_main_superagent?
      # This should be overridden in child classes.
      raise NotImplementedError, "actions index must be implemented in child classes"
    else
      @page_title = "Actions | #{current_superagent.name}"
      render 'shared/actions_index_studio', locals: {
        base_path: request.path.split('/actions')[0]
      }
    end
  end

  def render_action_description(locals)
    @page_title ||= "Action: #{locals[:action_name]}"
    render 'shared/action_description', locals: {
      action_name: locals[:action_name],
      resource: locals[:resource],
      description: locals[:description],
      params: locals[:params], # { name: 'param_name', type: 'string', description: 'description' }
    }
  end

  def render_action_success(locals)
    @page_title ||= "Action Success: #{locals[:action_name]}"
    render 'shared/action_success', locals: {
      action_name: locals[:action_name],
      resource: locals[:resource],
      result: locals[:result],
    }
  end

  def render_action_error(locals)
    @page_title ||= "Action Error: #{locals[:action_name]}"
    render 'shared/action_error', locals: {
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
      SecurityAuditLog.log_logout(user: current_person_user, ip: request.remote_ip, reason: "session_absolute_timeout") if current_person_user
      reset_session
      flash[:alert] = "Your session has expired. Please log in again."
      redirect_to '/login'
      return
    end

    # Idle timeout: session expires after inactivity (default 2 hours)
    if session[:last_activity_at].present? && Time.at(session[:last_activity_at]) < SESSION_IDLE_TIMEOUT.ago
      SecurityAuditLog.log_logout(user: current_person_user, ip: request.remote_ip, reason: "session_idle_timeout") if current_person_user
      reset_session
      flash[:alert] = "Your session has expired due to inactivity. Please log in again."
      redirect_to '/login'
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
    redirect_to '/login'
  end

  # Set Sentry context for error tracking
  def set_sentry_context
    return unless defined?(Sentry) && Sentry.initialized?

    Sentry.set_user(
      id: @current_user&.id,
      email: @current_user&.email,
      username: @current_user&.name,
      ip_address: request.remote_ip,
    )

    Sentry.set_tags(
      tenant_id: @current_tenant&.id,
      superagent_id: @current_superagent&.id,
      subdomain: request.subdomain,
    )

    Sentry.set_extras(
      user_type: @current_user&.user_type,
      api_request: api_token_present?,
    )
  end

end
