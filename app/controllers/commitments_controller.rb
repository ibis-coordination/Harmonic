# typed: false

class CommitmentsController < ApplicationController
  include AttachmentActions

  def new
    @page_title = "Commit"
    @page_description = "Start a group commitment"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_superagent.tempo)
    @sidebar_mode = 'resource'
    @team = @current_superagent.team
    @commitment = Commitment.new(
      title: params[:title],
    )
  end

  def create
    begin
      # Build params for ApiHelper
      helper_params = {
        title: model_params[:title],
        description: model_params[:description],
        critical_mass: model_params[:critical_mass],
        deadline: deadline_from_params,
        close_at_critical_mass: params[:deadline_option] == 'close_at_critical_mass',
      }
      @commitment = api_helper(params: helper_params).create_commitment
      # Handle file attachments separately (not in ApiHelper since it's HTML-form specific)
      if params[:files] && @current_tenant.allow_file_uploads? && @current_superagent.allow_file_uploads?
        @commitment.attach!(params[:files])
      end
      if params[:pinned] == '1' && current_superagent.id != current_tenant.main_studio_id
        api_helper.pin_resource(@commitment)
      end
      redirect_to @commitment.path
    rescue ActiveRecord::RecordInvalid => e
      @commitment ||= Commitment.new(
        title: model_params[:title],
        description: model_params[:description],
        critical_mass: model_params[:critical_mass],
      )
      flash.now[:alert] = 'There was an error creating the commitment. Please try again.'
      render :new
    end
  end

  def show
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    @commitment_participant = current_commitment_participant
    @commitment_participant_name = current_user&.name
    @participants_list_limit = 10
    @page_title = @commitment.title
    @page_description = "Coordinate with your team"
    @sidebar_mode = 'resource'
    @team = @current_superagent.team
    set_pin_vars
  end

  def status_partial
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    render partial: 'status'
  end

  def join_and_return_partial
    # Must be logged in to join
    unless current_user
      return render message: 'You must be logged in to join.', status: 401
    end
    @commitment = current_commitment
    if @commitment.closed?
      return render message: 'This commitment is closed.', status: 400
    end
    @commitment_participant = api_helper.join_commitment
    @commitment_participant_name = current_user.name
    render partial: 'join'
  end

  def participants_list_items_partial
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    @participants_list_limit = params[:limit].to_i if params[:limit].present?
    @participants_list_limit = 20 if @participants_list_limit < 1
    render partial: 'participants_list_items'
  end

  def settings
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    unless @commitment.can_edit_settings?(@current_user)
      @sidebar_mode = 'none'
      return render 'shared/403', status: 403
    end
    @page_title = "Commitment Settings"
    @page_description = "Change settings for this commitment"
    @sidebar_mode = 'resource'
    @team = @current_superagent.team
    set_pin_vars
  end

  def actions_index_new
    @page_title = "Actions | Commit"
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/commit'))
  end

  def actions_index_show
    @page_title = "Actions | #{current_commitment.title}"
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/c/:commitment_id'))
  end

  def describe_create_commitment
    render_action_description(ActionsHelper.action_description("create_commitment"))
  end

  def create_commitment_action
    return render_action_error({ action_name: 'create_commitment', error: 'You must be logged in.' }) unless current_user

    begin
      @commitment = api_helper.create_commitment
      render_action_success({
        action_name: 'create_commitment',
        resource: @commitment,
        result: "You have successfully created the commitment '#{@commitment.title}'",
      })
    rescue ActiveRecord::RecordInvalid, StandardError => e
      render_action_error({
        action_name: 'create_commitment',
        error: e.message,
      })
    end
  end

  def describe_join_commitment
    render_action_description(ActionsHelper.action_description("join_commitment", resource: current_commitment))
  end

  def join_commitment
    @commitment = current_commitment
    return render_action_error({ action_name: 'join_commitment', resource: @commitment, error: 'Not found' }) unless @commitment
    return render_action_error({ action_name: 'join_commitment', resource: @commitment, error: 'You must be logged in to join.' }) unless current_user
    return render_action_error({ action_name: 'join_commitment', resource: @commitment, error: 'This commitment is closed.' }) if @commitment.closed?

    begin
      @commitment_participant = api_helper.join_commitment
      render_action_success({
        action_name: 'join_commitment',
        resource: @commitment,
        result: "You have successfully joined the commitment '#{@commitment.title}'",
      })
    rescue ActiveRecord::RecordInvalid, StandardError => e
      render_action_error({
        action_name: 'join_commitment',
        resource: @commitment,
        error: e.message,
      })
    end
  end

  def update_settings
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    return render 'shared/403', status: 403 unless @commitment.can_edit_settings?(@current_user)

    # Check for lowering critical mass
    if model_params[:critical_mass].present?
      cm_is_lower = model_params[:critical_mass].to_i < @commitment.critical_mass.to_i
      if cm_is_lower && @commitment.participant_count > 0
        flash[:alert] = "You cannot lower the critical mass after participants have joined."
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
    @commitment = api_helper(params: helper_params).update_commitment_settings
    # Handle close_at_critical_mass option (HTML form specific)
    if params[:deadline_option] == 'close_at_critical_mass'
      @commitment.limit = @commitment.critical_mass
      @commitment.close_if_limit_reached
      @commitment.save!
    end
    redirect_to @commitment.path
  end

  def actions_index_settings
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    @page_title = "Actions | Commitment Settings"
    set_pin_vars
    actions = [
      { name: 'update_commitment_settings', params_string: '(title, description, critical_mass, deadline)' },
    ]
    if @is_pinned
      actions << { name: 'unpin_commitment', params_string: '()' }
    else
      actions << { name: 'pin_commitment', params_string: '()' }
    end
    render_actions_index({ actions: actions })
  end

  def describe_pin_commitment
    render_action_description(ActionsHelper.action_description("pin_commitment", resource: current_commitment))
  end

  def pin_commitment_action
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    begin
      api_helper.pin_resource(@commitment)
      render_action_success({
        action_name: 'pin_commitment',
        resource: @commitment,
        result: "Commitment pinned.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'pin_commitment',
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
    return render '404', status: 404 unless @commitment
    begin
      api_helper.unpin_resource(@commitment)
      render_action_success({
        action_name: 'unpin_commitment',
        resource: @commitment,
        result: "Commitment unpinned.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'unpin_commitment',
        resource: @commitment,
        error: e.message,
      })
    end
  end

  def describe_update_commitment_settings
    render_action_description(ActionsHelper.action_description("update_commitment_settings", resource: current_commitment))
  end

  def update_commitment_settings_action
    return render_action_error({ action_name: 'update_commitment_settings', resource: current_commitment, error: 'You must be logged in.' }) unless current_user

    begin
      commitment = api_helper.update_commitment_settings
      render_action_success({
        action_name: 'update_commitment_settings',
        resource: commitment,
        result: "Commitment settings updated successfully.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'update_commitment_settings',
        resource: current_commitment,
        error: e.message,
      })
    end
  end

  private

  def current_app
    return @current_app if defined?(@current_app)
    @current_app = 'coordinated'
    @current_app_title = 'Coordinated Team'
    @current_app_description = 'fast group coordination'
    @current_app
  end
end
