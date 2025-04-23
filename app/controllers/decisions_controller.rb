class DecisionsController < ApplicationController

  def new
    @page_title = "Decide"
    @page_description = "Make a group decision with Harmonic Team"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_studio.tempo)
    @scratchpad_links = current_user.scratchpad_links(tenant: current_tenant, studio: current_studio)
    @decision = Decision.new(
      question: params[:question],
    )
  end

  def create
    begin
      ActiveRecord::Base.transaction do
        @decision = @current_decision = Decision.create!(
          question: decision_params[:question],
          description: decision_params[:description],
          options_open: decision_params[:options_open],
          deadline: params[:end_of_cycle] == '1 hour from now' ? 1.hour.from_now : Cycle.new_from_end_of_cycle_option(
            end_of_cycle: params[:end_of_cycle],
            tenant: current_tenant,
            studio: current_studio,
          ).end_date,
          created_by: current_user,
        )
        if params[:files] && @current_tenant.allow_file_uploads? && @current_studio.allow_file_uploads?
          @decision.attach!(params[:files])
        end
        if params[:pinned] == '1' && current_studio.id != current_tenant.main_studio_id
          current_studio.pin_item!(@decision)
        end
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'create',
              studio_id: current_studio.id,
              main_resource: {
                type: 'Decision',
                id: @decision.id,
                truncated_id: @decision.truncated_id,
              },
              sub_resources: [],
            }
          )
        end
      end
      redirect_to @decision.path
    rescue ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.each do |msg|
        flash.now[:alert] = msg
      end
      @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_studio.tempo)
      @decision = Decision.new(
        question: decision_params[:question],
        description: decision_params[:description],
      )
      render :new
    end
  end

  def create_decision
    begin
      @decision = api_helper.create_decision
      render_action_success({
        action_name: 'create_decision',
        resource: @decision,
        result: 'You have successfully created a decision',
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'create_decision',
        resource: @decision,
        error: e.message,
      })
    end
  end

  def duplicate
    @decision = current_decision
    return render '404', status: 404 unless @decision
    @new_decision = Decision.new(
      tenant_id: @decision.tenant_id,
      studio_id: @decision.studio_id,
      question: @decision.question,
      description: @decision.description,
      options_open: @decision.options_open,
      deadline: Time.current + (@decision.deadline - @decision.created_at),
      created_by: current_user,
    )
    ActiveRecord::Base.transaction do
      @new_decision.save!
      dp = DecisionParticipantManager.new(
        decision: @new_decision,
        user: current_user
      ).find_or_create_participant
      options = @decision.options.map do |option|
        Option.create!(
          tenant_id: option.tenant_id,
          studio_id: option.studio_id,
          decision_id: @new_decision.id,
          decision_participant_id: dp.id,
          title: option.title,
        )
      end
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'create',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Decision',
              id: @decision.id,
              truncated_id: @decision.truncated_id,
            },
            sub_resources: options.map do |option|
              {
                type: 'Option',
                id: option.id,
              }
            end,
          }
        )
      end
    end
    redirect_to @new_decision.path
  end

  def show
    @decision = current_decision
    return render '404', status: 404 unless @decision
    @participant = current_decision_participant
    @page_title = @decision.question
    @page_description = "Decide as a group with Harmonic Team"
    @options_header = @decision.can_add_options?(@participant) ? 'Add Options & Vote' : 'Vote'

    @approvals = current_approvals
    set_results_view_vars
    set_pin_vars
  end

  def settings
    @decision = current_decision
    return render '404', status: 404 unless @decision
    @page_title = "Decision Settings"
    @page_description = "Change settings for this decision"
    @scratchpad_links = current_user.scratchpad_links(tenant: current_tenant, studio: current_studio)
  end

  def update_settings
    @decision = current_decision
    return render '404', status: 404 unless @decision
    @decision.question = decision_params[:question] if decision_params[:question].present?
    @decision.description = decision_params[:description] if decision_params[:description].present?
    @decision.options_open = decision_params[:options_open] if decision_params[:options_open].present?
    # The datetime select is in the studio timezone, so we need to convert it to UTC
    # @decision.deadline = Time.zone.parse("#{params[:deadline]} #{params[:deadline_time]}").utc
    ActiveRecord::Base.transaction do
      @decision.save!
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'update',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Decision',
              id: @decision.id,
              truncated_id: @decision.truncated_id,
            },
            sub_resources: [],
          }
        )
      end
    end
    redirect_to @decision.path
  end

  def options_partial
    @decision = current_decision
    @approvals = current_approvals
    render partial: 'options_list_items'
  end

  def create_option_and_return_options_partial
    ActiveRecord::Base.transaction do
      option = Option.create!(
        decision: current_decision,
        decision_participant: current_decision_participant,
        title: params[:title],
        description: params[:description],
      )
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'add_option',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Decision',
              id: current_decision.id,
              truncated_id: current_decision.truncated_id,
            },
            sub_resources: [
              {
                type: 'Option',
                id: option.id,
              },
            ],
          }
        )
      end
    end
    options_partial
  end

  def results_partial
    @decision = current_decision
    set_results_view_vars
    render partial: 'results'
  end

  def voters_partial
    @decision = current_decision
    render partial: 'voters'
  end

  def actions_index_new
    @page_title = 'Actions | Decide'
    render_actions_index(ActionsHelper.actions_for_route('/s/:studio_handle/decide'))
  end

  def actions_index_show
    @page_title = "Actions | #{@decision.question}"
    render_actions_index(ActionsHelper.actions_for_route('/s/:studio_handle/d/:decision_id'))
  end

  def describe_create_decision
    @page_title = 'Create Decision'
    @page_description = 'Create a new decision'
    render_action_description({
      action_name: 'create_decision',
      resource: current_decision,
      description: 'Create a new decision',
      params: [{
        name: 'question',
        description: 'The question to be decided',
        type: 'string',
      }, {
        name: 'description',
        description: 'A description of the decision',
        type: 'string',
      }, {
        name: 'options_open',
        description: 'Whether to allow adding options',
        type: 'boolean',
      }, {
        name: 'deadline',
        description: 'The deadline for the decision',
        type: 'datetime',
      }]
    })
  end

  private

  def decision_params
    model_params.permit(
      :question, :description, :options_open,
      :duration, :duration_unit, :files
    )
  end

  def set_results_view_vars
    @voter_count = @decision.voter_count
    @results_header = @decision.closed? ? 'Final Results' : 'Current Results'
  end

  def current_app
    return @current_app if defined?(@current_app)
    @current_app = 'decisive'
    @current_app_title = 'Harmonic Team'
    @current_app_description = 'fast group decision-making'
    @current_app
  end
end
