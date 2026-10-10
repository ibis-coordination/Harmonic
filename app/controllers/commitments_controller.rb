# typed: false

class CommitmentsController < ApplicationController
  include AttachmentActions

  allows_anonymous :show, :summary
  before_action :set_no_cache_headers, only: [:show, :summary]
  before_action :enforce_anonymous_read_rate_limit, only: [:show, :summary]

  def summary
    render_summary_for(current_commitment)
  end

  def show
    @commitment = current_commitment || find_deleted_commitment
    return render "404", status: :not_found unless @commitment

    @page_title = @commitment.title
    @page_description = excerpt(@commitment.description.presence || @commitment.title, max: 200) ||
                        "Coordinate with your team"
    @sidebar_mode = "resource"
    @team = @current_collective.team
    return if @commitment.deleted?

    @commitment_participant = current_commitment_participant
    @commitment_participant_name = current_user&.name
    @participants_list_limit = 10
    set_pin_vars
    set_report_vars(@commitment)
  end

  def new
    @page_title = "Commit"
    @page_description = "Start a group commitment"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_collective.tempo)
    @sidebar_mode = "resource"
    @team = @current_collective.team
    @subtype = Commitment::SUBTYPES.include?(params[:subtype]) ? params[:subtype] : "action"
    @commitment = Commitment.new(
      title: params[:title],
      subtype: @subtype
    )
  end

  def create
    @subtype = Commitment::SUBTYPES.include?(model_params[:subtype]) ? model_params[:subtype] : "action"
    # Build params for ApiHelper
    helper_params = {
      title: model_params[:title],
      description: model_params[:description],
      subtype: @subtype,
      critical_mass: model_params[:critical_mass],
      deadline: deadline_from_params,
      close_at_critical_mass: params[:deadline_option] == "close_at_critical_mass",
    }
    if @subtype == "calendar_event"
      # DatetimeInputComponent submits a per-input timezone alongside each
      # datetime-local value; fall back to the collective's timezone.
      collective_tz = current_collective.timezone&.name
      helper_params[:starts_at] = parse_scheduled_time(
        model_params[:starts_at],
        timezone: model_params[:starts_at_timezone].presence || collective_tz,
      )
      # The form gives the user a duration (more natural than an end time);
      # the server derives ends_at. API/markdown callers can still pass
      # ends_at directly if they prefer.
      if model_params[:duration_minutes].present? && helper_params[:starts_at]
        helper_params[:ends_at] = helper_params[:starts_at] + model_params[:duration_minutes].to_i.minutes
      elsif model_params[:ends_at].present?
        helper_params[:ends_at] = parse_scheduled_time(
          model_params[:ends_at],
          timezone: model_params[:ends_at_timezone].presence || collective_tz,
        )
      end
      helper_params[:location] = model_params[:location]
      # Default the closing deadline to the event start if the user didn't
      # pick one (RSVP deadline is optional for events).
      helper_params[:deadline] ||= helper_params[:starts_at]
    end
    @commitment = api_helper(params: helper_params).create_commitment
    # Handle file attachments separately (not in ApiHelper since it's HTML-form specific)
    @commitment.attach!(params[:files]) if params[:files] && @current_tenant.allow_file_uploads? && @current_collective.allow_file_uploads?
    api_helper.pin_resource(@commitment) if params[:pinned] == "1" && current_collective.id != current_tenant.main_collective_id
    redirect_to @commitment.path
  rescue ActiveRecord::RecordInvalid
    @commitment ||= Commitment.new(
      title: model_params[:title],
      description: model_params[:description],
      critical_mass: model_params[:critical_mass],
      subtype: @subtype
    )
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_collective.tempo)
    @sidebar_mode = "resource"
    @team = @current_collective.team
    flash.now[:alert] = "There was an error creating the commitment. Please try again."
    render :new, status: :unprocessable_entity
  end

  def report
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment
    return redirect_to("/login") unless @current_user

    @reportable = @commitment
    @reportable_type = "Commitment"
    @reportable_id = @commitment.id
    @page_title = "Report Content"
    @sidebar_mode = "resource"
    render "content_reports/new"
  end

  def status_partial
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment

    render partial: "status"
  end

  def join_and_return_partial
    # Must be logged in to join
    return render message: "You must be logged in to join.", status: :unauthorized unless current_user

    @commitment = current_commitment
    return render message: "This commitment is closed.", status: :bad_request if @commitment.closed?

    @commitment_participant = api_helper.join_commitment
    @commitment_participant_name = current_user.name
    render partial: "join"
  end

  def participants_list_items_partial
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment

    @participants_list_limit = params[:limit].to_i if params[:limit].present?
    @participants_list_limit = 20 if @participants_list_limit < 1
    render partial: "participants_list_items"
  end

  def settings
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment

    unless @commitment.can_edit_settings?(@current_user)
      @sidebar_mode = "none"
      return render "shared/403", status: :forbidden
    end
    type_label = if @commitment.is_policy?
                   "Policy"
                 elsif @commitment.is_calendar_event?
                   "Event"
                 else
                   "Commitment"
                 end
    @page_title = "#{type_label} Settings"
    @page_description = "Change settings for this #{type_label.downcase}"
    @sidebar_mode = "resource"
    @team = @current_collective.team
    set_pin_vars
  end

  def actions_index_new
    @page_title = "Actions | Commit"
    render_actions_index(ActionsHelper.actions_for_route("/collectives/:collective_handle/commit"))
  end

  def actions_index_show
    @commitment = current_commitment
    @page_title = "Actions | #{@commitment.title}"
    route_info = ActionsHelper.actions_for_route("/collectives/:collective_handle/c/:commitment_id")
    actions = (route_info&.dig(:actions) || []).select do |action|
      ActionAuthorization.authorized?(action[:name], @current_user, { collective: @current_collective, resource: @commitment })
    end
    render_actions_index({ actions: actions })
  end

  def describe_create_commitment
    render_action_description(ActionsHelper.action_description("create_commitment"))
  end

  def create_commitment_action
    return render_action_error({ action_name: "create_commitment", error: "You must be logged in.", status: :unauthorized }) unless current_user

    begin
      @commitment = api_helper.create_commitment
      type_label = if @commitment.is_policy?
                     "policy"
                   elsif @commitment.is_calendar_event?
                     "event"
                   else
                     "commitment"
                   end
      render_action_success({
                              action_name: "create_commitment",
                              resource: @commitment,
                              result: "You have successfully created the #{type_label} '#{@commitment.title}'",
                            })
    rescue ActiveRecord::RecordInvalid, StandardError => e
      render_action_error({
                            action_name: "create_commitment",
                            error: e.message,
                          })
    end
  end

  def describe_report_content
    render_action_description(ActionsHelper.action_description("report_content", resource: current_commitment))
  end

  def report_content_action
    return render "404", status: :not_found unless current_commitment

    api_helper.report_content(current_commitment)
    respond_to do |format|
      format.html { redirect_to current_commitment.path, notice: report_content_flash }
      format.md { render_action_success({ action_name: "report_content", resource: current_commitment, result: report_content_flash }) }
    end
  rescue ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.html { redirect_to current_commitment.path, alert: e.record.errors.full_messages.join(", ") }
      format.md { render_action_error({ action_name: "report_content", resource: current_commitment, error: e.message }) }
    end
  end

  def describe_join_commitment
    render_action_description(ActionsHelper.action_description("join_commitment", resource: current_commitment))
  end

  def join_commitment
    @commitment = current_commitment
    return render_action_error({ action_name: "join_commitment", resource: @commitment, error: "Not found", status: :not_found }) unless @commitment
    return render_action_error({ action_name: "join_commitment", resource: @commitment, error: "You must be logged in to join.", status: :unauthorized }) unless current_user
    return render_action_error({ action_name: "join_commitment", resource: @commitment, error: "This commitment is closed.", status: :conflict }) if @commitment.closed?

    begin
      @commitment_participant = api_helper.join_commitment
      result = if @commitment.is_policy?
                 "You have successfully signed the policy '#{@commitment.title}'"
               elsif @commitment.is_calendar_event?
                 "You have successfully RSVP'd to the event '#{@commitment.title}'"
               else
                 "You have successfully joined the commitment '#{@commitment.title}'"
               end
      render_action_success({
                              action_name: "join_commitment",
                              resource: @commitment,
                              result: result,
                            })
    rescue ActiveRecord::RecordInvalid, StandardError => e
      render_action_error({
                            action_name: "join_commitment",
                            resource: @commitment,
                            error: e.message,
                          })
    end
  end

  def update_settings
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment
    return render "shared/403", status: :forbidden unless @commitment.can_edit_settings?(@current_user)

    # Check for lowering/removing critical mass. Clearing the field counts as
    # lowering — a critical-mass rule can't be removed once people joined
    # under it.
    if @commitment.participant_count > 0
      cm_param = model_params[:critical_mass]
      clearing = cm_param == "" && @commitment.has_critical_mass?
      lowering = cm_param.present? && cm_param.to_i < @commitment.critical_mass.to_i
      if clearing || lowering
        flash[:alert] = "You cannot lower or remove the critical mass after participants have joined."
        redirect_to @commitment.path
        return
      end
    end

    # Build params for ApiHelper
    helper_params = {
      title: model_params[:title],
      description: model_params[:description],
      critical_mass: model_params[:critical_mass],
      deadline: deadline_from_params,
    }
    if @commitment.is_calendar_event?
      # Same timezone handling as create: DatetimeInputComponent submits a
      # per-input timezone alongside each datetime-local value.
      collective_tz = current_collective.timezone&.name
      if model_params[:starts_at].present?
        helper_params[:starts_at] = parse_scheduled_time(
          model_params[:starts_at],
          timezone: model_params[:starts_at_timezone].presence || collective_tz,
        )
      end
      if model_params[:ends_at].present?
        helper_params[:ends_at] = parse_scheduled_time(
          model_params[:ends_at],
          timezone: model_params[:ends_at_timezone].presence || collective_tz,
        )
      end
      helper_params[:location] = model_params[:location] if model_params.key?(:location)
    end
    @commitment = api_helper(params: helper_params).update_commitment_settings
    # Handle close_at_critical_mass option (HTML form specific)
    if params[:deadline_option] == "close_at_critical_mass" && @commitment.has_critical_mass?
      @commitment.limit = @commitment.critical_mass
      @commitment.close_if_limit_reached
      @commitment.save!
    end
    redirect_to @commitment.path
  rescue ActiveRecord::RecordInvalid => e
    redirect_to "#{current_commitment.path}/settings", alert: e.record.errors.full_messages.join(", ")
  end

  def actions_index_settings
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment

    type_label = if @commitment.is_policy?
                   "Policy"
                 elsif @commitment.is_calendar_event?
                   "Event"
                 else
                   "Commitment"
                 end
    @page_title = "Actions | #{type_label} Settings"
    set_pin_vars
    actions = [
      { name: "update_commitment_settings",
        params_string: ActionsHelper::ACTION_DEFINITIONS["update_commitment_settings"][:params_string], },
    ]
    actions << if @is_pinned
                 { name: "unpin_commitment", params_string: "()" }
               else
                 { name: "pin_commitment", params_string: "()" }
               end
    if @current_user&.id == @commitment.created_by_id || @current_user&.collective_member&.is_admin? || @current_user&.app_admin?
      actions << { name: "delete_commitment", params_string: "()" }
    end
    render_actions_index({ actions: actions })
  end

  def describe_pin_commitment
    render_action_description(ActionsHelper.action_description("pin_commitment", resource: current_commitment))
  end

  def pin_commitment_action
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment

    begin
      api_helper.pin_resource(@commitment)
      render_action_success({
                              action_name: "pin_commitment",
                              resource: @commitment,
                              result: "Commitment pinned.",
                            })
    rescue StandardError => e
      render_action_error({
                            action_name: "pin_commitment",
                            resource: @commitment,
                            error: e.message,
                          })
    end
  end

  def describe_unpin_commitment
    render_action_description(ActionsHelper.action_description("unpin_commitment", resource: current_commitment))
  end

  def unpin_commitment_action
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment

    begin
      api_helper.unpin_resource(@commitment)
      render_action_success({
                              action_name: "unpin_commitment",
                              resource: @commitment,
                              result: "Commitment unpinned.",
                            })
    rescue StandardError => e
      render_action_error({
                            action_name: "unpin_commitment",
                            resource: @commitment,
                            error: e.message,
                          })
    end
  end

  def describe_update_commitment_settings
    render_action_description(ActionsHelper.action_description("update_commitment_settings", resource: current_commitment))
  end

  def update_commitment_settings_action
    unless current_user
      return render_action_error({ action_name: "update_commitment_settings", resource: current_commitment,
                                   error: "You must be logged in.", status: :unauthorized, })
    end

    begin
      commitment = api_helper.update_commitment_settings
      render_action_success({
                              action_name: "update_commitment_settings",
                              resource: commitment,
                              result: "Commitment settings updated successfully.",
                            })
    rescue StandardError => e
      render_action_error({
                            action_name: "update_commitment_settings",
                            resource: current_commitment,
                            error: e.message,
                          })
    end
  end

  def describe_delete_commitment
    render_action_description(ActionsHelper.action_description("delete_commitment", resource: current_commitment))
  end

  def execute_delete_commitment
    @commitment = current_commitment
    return render "404", status: :not_found unless @commitment

    begin
      api_helper.delete_commitment
      redirect_to(@current_collective.path || "/", notice: "Commitment deleted.")
    rescue ActiveRecord::RecordInvalid
      render "shared/403", status: :forbidden
    end
  end

  private

  def current_app
    return @current_app if defined?(@current_app)

    @current_app = "coordinated"
    @current_app_title = "Coordinated Team"
    @current_app_description = "fast group coordination"
    @current_app
  end

  def find_deleted_commitment
    commitment_id = params[:id] || params[:commitment_id]
    return nil unless commitment_id

    if commitment_id.to_s.length == 8
      Commitment.with_deleted.find_by(truncated_id: commitment_id)
    else
      Commitment.with_deleted.find_by(id: commitment_id)
    end
  end
end
