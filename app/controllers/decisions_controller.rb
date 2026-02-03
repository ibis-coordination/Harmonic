# typed: false

class DecisionsController < ApplicationController
  include AttachmentActions

  layout 'pulse', only: [:show, :new, :edit, :settings]

  def new
    @page_title = "Decide"
    @page_description = "Make a group decision with Harmonic Team"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_superagent.tempo)
    @sidebar_mode = 'resource'
    @team = @current_superagent.team
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
          deadline: deadline_from_params,
          created_by: current_user,
        )
        if params[:files] && @current_tenant.allow_file_uploads? && @current_superagent.allow_file_uploads?
          @decision.attach!(params[:files])
        end
        if params[:pinned] == '1' && current_superagent.id != current_tenant.main_studio_id
          current_superagent.pin_item!(@decision)
        end
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'create',
              superagent_id: current_superagent.id,
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
      @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_superagent.tempo)
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
      superagent_id: @decision.superagent_id,
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
          superagent_id: option.studio_id,
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
            superagent_id: current_superagent.id,
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
    @sidebar_mode = 'resource'
    @team = @current_superagent.team
    @options_header = @decision.can_add_options?(@participant) ? 'Add Options & Vote' : 'Vote'

    @votes = current_votes
    set_results_view_vars
    set_pin_vars
  end

  def settings
    @decision = current_decision
    return render '404', status: 404 unless @decision
    unless @decision.can_edit_settings?(@current_user)
      @sidebar_mode = 'none'
      return render 'shared/403', status: 403
    end
    @page_title = "Decision Settings"
    @page_description = "Change settings for this decision"
    @sidebar_mode = 'resource'
    @team = @current_superagent.team
    set_pin_vars
  end

  def update_settings
    @decision = current_decision
    return render '404', status: 404 unless @decision
    return render 'shared/403', status: 403 unless @decision.can_edit_settings?(@current_user)
    @decision.question = decision_params[:question] if decision_params[:question].present?
    @decision.description = decision_params[:description] if decision_params[:description].present?
    @decision.options_open = decision_params[:options_open] if decision_params[:options_open].present?
    deadline = deadline_from_params
    @decision.deadline = deadline unless deadline.nil?
    ActiveRecord::Base.transaction do
      @decision.save!
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'update',
            superagent_id: current_superagent.id,
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

  def actions_index_settings
    @decision = current_decision
    return render '404', status: 404 unless @decision
    @page_title = "Actions | Decision Settings"
    set_pin_vars
    actions = [
      { name: 'update_decision_settings', params_string: '(question, description, options_open, deadline)' },
    ]
    if @is_pinned
      actions << { name: 'unpin_decision', params_string: '()' }
    else
      actions << { name: 'pin_decision', params_string: '()' }
    end
    render_actions_index({ actions: actions })
  end

  def describe_pin_decision
    render_action_description(ActionsHelper.action_description("pin_decision", resource: current_decision))
  end

  def pin_decision_action
    @decision = current_decision
    return render '404', status: 404 unless @decision
    begin
      @decision.pin!(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
      render_action_success({
        action_name: 'pin_decision',
        resource: @decision,
        result: "Decision pinned.",
      })
    rescue => e
      render_action_error({
        action_name: 'pin_decision',
        resource: @decision,
        error: e.message,
      })
    end
  end

  def describe_unpin_decision
    render_action_description(ActionsHelper.action_description("unpin_decision", resource: current_decision))
  end

  def unpin_decision_action
    @decision = current_decision
    return render '404', status: 404 unless @decision
    begin
      @decision.unpin!(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
      render_action_success({
        action_name: 'unpin_decision',
        resource: @decision,
        result: "Decision unpinned.",
      })
    rescue => e
      render_action_error({
        action_name: 'unpin_decision',
        resource: @decision,
        error: e.message,
      })
    end
  end

  def describe_update_decision_settings
    render_action_description(ActionsHelper.action_description("update_decision_settings", resource: current_decision))
  end

  def update_decision_settings_action
    return render_action_error({ action_name: 'update_decision_settings', resource: current_decision, error: 'You must be logged in.' }) unless current_user

    begin
      decision = api_helper.update_decision_settings
      render_action_success({
        action_name: 'update_decision_settings',
        resource: decision,
        result: "Decision settings updated successfully.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'update_decision_settings',
        resource: current_decision,
        error: e.message,
      })
    end
  end

  def options_partial
    @decision = current_decision
    @votes = current_votes
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
            event_type: 'add_options',
            superagent_id: current_superagent.id,
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

  def add_options
    begin
      @options = api_helper.create_decision_options
      titles = @options.map(&:title).map { |t| "'#{t}'" }.join(", ")
      render_action_success({
        action_name: "add_options",
        resource: @options.first.decision,
        result: "You have successfully added #{@options.count} option#{'s' if @options.count > 1}: #{titles}",
      })
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      render_action_error({
        action_name: "add_options",
        resource: current_decision,
        error: e.message,
      })
    end
  end

  def vote
    begin
      @votes = api_helper.create_votes
      option_titles = @votes.map { |v| "'#{v.option.title}'" }.join(", ")
      render_action_success({
        action_name: "vote",
        resource: @votes.first.decision,
        result: "You have successfully voted on #{@votes.count} option#{'s' if @votes.count > 1}: #{option_titles}",
      })
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      render_action_error({
        action_name: "vote",
        resource: current_decision,
        error: e.message,
      })
    end
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
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/decide'))
  end

  def actions_index_show
    @page_title = "Actions | #{current_decision.question}"
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/d/:decision_id'))
  end

  def describe_create_decision
    @page_title = 'Create Decision'
    @page_description = 'Create a new decision'
    render_action_description(ActionsHelper.action_description("create_decision"))
  end

  def describe_add_options
    render_action_description(ActionsHelper.action_description("add_options", resource: current_decision))
  end

  def describe_vote
    render_action_description(ActionsHelper.action_description("vote", resource: current_decision))
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
