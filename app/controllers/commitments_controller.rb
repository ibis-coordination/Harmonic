# typed: false

class CommitmentsController < ApplicationController

  def new
    @page_title = "Commit"
    @page_description = "Start a group commitment"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_studio.tempo)
    @commitment = Commitment.new(
      title: params[:title],
    )
  end

  def create
    @commitment = Commitment.new(
      title: model_params[:title],
      description: model_params[:description],
      critical_mass: model_params[:critical_mass],
      deadline: deadline_from_params,
      created_by: current_user,
    )
    @commitment.limit = @commitment.critical_mass if params[:deadline_option] == 'close_at_critical_mass'
    begin
      ActiveRecord::Base.transaction do
        @commitment.save!
        if params[:files] && @current_tenant.allow_file_uploads? && @current_studio.allow_file_uploads?
          @commitment.attach!(params[:files])
        end
        if params[:pinned] == '1' && current_studio.id != current_tenant.main_studio_id
          current_studio.pin_item!(@commitment)
        end
        @current_commitment = @commitment
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'create',
              studio_id: current_studio.id,
              main_resource: {
                type: 'Commitment',
                id: @commitment.id,
                truncated_id: @commitment.truncated_id,
              },
              sub_resources: [],
            }
          )
        end
      end
      redirect_to @commitment.path
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = 'There was an error creating the commitment. Please try again.'
      render :new
    end
  end

  def show
    @commitment = current_commitment
    return render '404', status: 404 unless @commitment
    @commitment_participant = current_commitment_participant
    if current_user
      @commitment_participant_name = @commitment_participant.name || current_user.name
    else
      @commitment_participant_name = @commitment_participant.name
    end
    @participants_list_limit = 10
    @page_title = @commitment.title
    @page_description = "Coordinate with your team"
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
    @commitment_participant = current_commitment_participant
    @commitment_participant_name = @commitment_participant.name || current_user.name
    @commitment_participant.committed = true if params[:committed].to_s == 'true'
    @commitment_participant.name = @commitment_participant_name
    ActiveRecord::Base.transaction do
      @commitment_participant.save!
      @commitment.close_if_limit_reached!
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'commit',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Commitment',
              id: @commitment.id,
              truncated_id: @commitment.truncated_id,
            },
            sub_resources: [
              {
                type: 'CommitmentParticipant',
                id: @commitment_participant.id,
              }
            ],
          }
        )
      end
    end
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
    return render 'shared/403', status: 403 unless @commitment.can_edit_settings?(@current_user)
    @page_title = "Commitment Settings"
    @page_description = "Change settings for this commitment"
  end

  def actions_index_show
    @page_title = "Actions | #{current_commitment.title}"
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/c/:commitment_id'))
  end

  def describe_join_commitment
    render_action_description({
      action_name: 'join_commitment',
      resource: current_commitment,
      description: 'Join the commitment',
      params: [],
    })
  end

  def join_commitment
    @commitment = current_commitment
    return render_action_error({ action_name: 'join_commitment', resource: @commitment, error: 'Not found' }) unless @commitment
    return render_action_error({ action_name: 'join_commitment', resource: @commitment, error: 'You must be logged in to join.' }) unless current_user
    return render_action_error({ action_name: 'join_commitment', resource: @commitment, error: 'This commitment is closed.' }) if @commitment.closed?

    begin
      @commitment_participant = current_commitment_participant
      @commitment_participant_name = @commitment_participant.name || current_user.name
      @commitment_participant.committed = true
      @commitment_participant.name = @commitment_participant_name
      ActiveRecord::Base.transaction do
        @commitment_participant.save!
        @commitment.close_if_limit_reached!
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'commit',
              studio_id: current_studio.id,
              main_resource: {
                type: 'Commitment',
                id: @commitment.id,
                truncated_id: @commitment.truncated_id,
              },
              sub_resources: [
                {
                  type: 'CommitmentParticipant',
                  id: @commitment_participant.id,
                }
              ],
            }
          )
        end
      end
      render_action_success({
        action_name: 'join_commitment',
        resource: @commitment,
        result: "You have successfully joined the commitment '#{@commitment.title}'",
      })
    rescue ActiveRecord::RecordInvalid => e
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
    @commitment.title = model_params[:title] if model_params[:title].present?
    @commitment.description = model_params[:description] if model_params[:description].present?
    if model_params[:critical_mass].present?
      cm_is_lower = model_params[:critical_mass].to_i < @commitment.critical_mass.to_i
    else
      cm_is_lower = false
    end
    if cm_is_lower && @commitment.participant_count > 0
      flash[:alert] = "You cannot lower the critical mass after participants have joined."
    else
      @commitment.critical_mass = model_params[:critical_mass] if model_params[:critical_mass].present?
    end
    deadline = deadline_from_params
    @commitment.deadline = deadline unless deadline.nil?
    @commitment.limit = @commitment.critical_mass if params[:deadline_option] == 'close_at_critical_mass'
    @commitment.close_if_limit_reached
    ActiveRecord::Base.transaction do
      @commitment.save!
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'update',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Commitment',
              id: @commitment.id,
              truncated_id: @commitment.truncated_id,
            },
            sub_resources: [],
          }
        )
      end
    end
    redirect_to @commitment.path
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
