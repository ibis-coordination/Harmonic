# typed: false

class DecisionsController < ApplicationController
  include AttachmentActions

  def new
    @page_title = "Decide"
    @page_description = "Make a group decision with Harmonic Team"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_collective.tempo)
    @sidebar_mode = 'resource'
    @team = @current_collective.team
    @decision = Decision.new(
      question: params[:question],
    )
  end

  def create
    begin
      # Build params for ApiHelper
      helper_params = {
        question: decision_params[:question],
        description: decision_params[:description],
        options_open: decision_params[:options_open],
        deadline: deadline_from_params,
      }
      @decision = @current_decision = api_helper(params: helper_params).create_decision
      # Handle file attachments separately (HTML form specific)
      if params[:files] && @current_tenant.allow_file_uploads? && @current_collective.allow_file_uploads?
        @decision.attach!(params[:files])
      end
      # Handle pinning (HTML form specific)
      if params[:pinned] == '1' && current_collective.id != current_tenant.main_collective_id
        api_helper.pin_resource(@decision)
      end
      redirect_to @decision.path
    rescue ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.each do |msg|
        flash.now[:alert] = msg
      end
      @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_collective.tempo)
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
    @new_decision = api_helper.duplicate_decision
    redirect_to @new_decision.path
  end

  def show
    @decision = current_decision || find_deleted_decision
    return render '404', status: 404 unless @decision

    @page_title = @decision.question
    @page_description = "Decide as a group with Harmonic Team"
    @sidebar_mode = 'resource'
    @team = @current_collective.team
    return if @decision.deleted?

    @participant = current_decision_participant
    @options_header = @decision.can_add_options?(@participant) ? 'Add Options & Vote' : 'Vote'
    @votes = current_votes
    @current_user_has_voted = @votes.any? { |v| v.accepted == 1 || v.preferred == 1 }
    @show_results = @decision.closed? || @current_user_has_voted
    set_results_view_vars
    set_pin_vars
    set_report_vars(@decision)
  end

  def report
    @decision = current_decision
    return render "404", status: :not_found unless @decision
    return redirect_to("/login") unless @current_user

    @reportable = @decision
    @reportable_type = "Decision"
    @reportable_id = @decision.id
    @page_title = "Report Content"
    @sidebar_mode = "resource"
    render "content_reports/new"
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
    @team = @current_collective.team
    set_pin_vars
  end

  def update_settings
    @decision = current_decision
    return render '404', status: 404 unless @decision
    return render 'shared/403', status: 403 unless @decision.can_edit_settings?(@current_user)

    # Build params for ApiHelper
    helper_params = {
      question: decision_params[:question],
      description: decision_params[:description],
      options_open: decision_params[:options_open],
      deadline: deadline_from_params,
    }
    @decision = api_helper(params: helper_params).update_decision_settings
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
    if @current_user&.id == @decision.created_by_id || @current_user&.collective_member&.is_admin? || @current_user&.app_admin?
      actions << { name: 'delete_decision', params_string: '()' }
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
      api_helper.pin_resource(@decision)
      render_action_success({
        action_name: 'pin_decision',
        resource: @decision,
        result: "Decision pinned.",
      })
    rescue StandardError => e
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
      api_helper.unpin_resource(@decision)
      render_action_success({
        action_name: 'unpin_decision',
        resource: @decision,
        result: "Decision unpinned.",
      })
    rescue StandardError => e
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
    api_helper.create_decision_option
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

  def submit_votes
    @decision = current_decision
    return render '404', status: 404 unless @decision
    if @decision.closed?
      redirect_to @decision.path, alert: "This decision is closed and no longer accepting votes."
      return
    end

    raw_votes = params[:votes]
    votes_list = if raw_votes.is_a?(ActionController::Parameters)
      raw_votes.values
    else
      raw_votes || []
    end

    votes_data = votes_list.map do |vote_params|
      {
        option_title: vote_params[:option_title],
        accept: vote_params[:accepted] == "1",
        prefer: vote_params[:preferred] == "1",
      }
    end

    if votes_data.any?
      begin
        api_helper(params: { votes: votes_data }).create_votes
        redirect_to @decision.path, notice: "Vote submitted."
      rescue StandardError => e
        redirect_to @decision.path, alert: e.message
      end
    else
      redirect_to @decision.path
    end
  end

  def results_partial
    @decision = current_decision
    set_results_view_vars
    render partial: 'results'
  end

  def voters_page
    @decision = current_decision || find_deleted_decision
    return render '404', status: 404 unless @decision
    return render '404', status: 404 if @decision.deleted?
    if @current_user && @decision.created_by && UserBlock.between?(@current_user, @decision.created_by)
      return render 'shared/403', status: 403
    end

    @page_title = "Voters | #{@decision.question}"
    @sidebar_mode = 'resource'

    all_votes = @decision.votes.includes(:option, decision_participant: :user)
    results = @decision.results
    result_option_ids = results.map(&:option_id)
    # Use results order; append any options not yet in results (no votes yet)
    all_options = @decision.options.order(:created_at)
    options_by_id = all_options.index_by(&:id)
    sorted_options = result_option_ids.filter_map { |id| options_by_id[id] }
    remaining = all_options.reject { |o| result_option_ids.include?(o.id) }
    sorted_options += remaining

    @votes_by_option = sorted_options.map do |option|
      option_votes = all_votes.select { |v| v.option_id == option.id }
      accepted_votes = option_votes.select { |v| v.accepted == 1 }
      {
        option: option,
        accepted_and_preferred: accepted_votes.select { |v| v.preferred == 1 }.map { |v| v.decision_participant.user }.compact.sort_by { |u| u.display_name.downcase },
        accepted_only: accepted_votes.select { |v| v.preferred != 1 }.map { |v| v.decision_participant.user }.compact.sort_by { |u| u.display_name.downcase },
      }
    end

    @votes_by_voter = @decision.voters.sort_by { |u| u.display_name.downcase }.map do |voter|
      voter_votes = all_votes.select { |v| v.decision_participant&.user_id == voter.id && v.accepted == 1 }
      # Sort accepted options in results order
      options_with_status = voter_votes.map do |v|
        { option: v.option, preferred: v.preferred == 1 }
      end.sort_by { |entry| result_option_ids.index(entry[:option].id) || Float::INFINITY }
      {
        voter: voter,
        options: options_with_status,
      }
    end
  end

  def voters_partial
    @decision = current_decision
    render partial: 'voters'
  end

  def actions_index_new
    @page_title = 'Actions | Decide'
    render_actions_index(ActionsHelper.actions_for_route('/collectives/:collective_handle/decide'))
  end

  def actions_index_show
    @decision = current_decision
    @page_title = "Actions | #{@decision.question}"
    route_info = ActionsHelper.actions_for_route("/collectives/:collective_handle/d/:decision_id")
    actions = (route_info&.dig(:actions) || []).select do |action|
      ActionAuthorization.authorized?(action[:name], @current_user, { collective: @current_collective, resource: @decision })
    end
    render_actions_index({ actions: actions })
  end

  def describe_create_decision
    @page_title = 'Create Decision'
    @page_description = 'Create a new decision'
    render_action_description(ActionsHelper.action_description("create_decision"))
  end

  def describe_report_content
    render_action_description(ActionsHelper.action_description("report_content", resource: current_decision))
  end

  def report_content_action
    return render "404", status: :not_found unless current_decision

    api_helper.report_content(current_decision)
    respond_to do |format|
      format.html { redirect_to current_decision.path, notice: report_content_flash }
      format.md { render_action_success({ action_name: "report_content", resource: current_decision, result: report_content_flash }) }
    end
  rescue ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.html { redirect_to current_decision.path, alert: e.record.errors.full_messages.join(", ") }
      format.md { render_action_error({ action_name: "report_content", resource: current_decision, error: e.message }) }
    end
  end

  def describe_close_decision
    render_action_description(ActionsHelper.action_description("close_decision", resource: current_decision))
  end

  def close_decision_action
    @decision = current_decision
    return render '404', status: 404 unless @decision
    return render 'shared/403', status: 403 unless @decision.can_close?(@current_user)

    begin
      api_helper(params: { final_statement: params[:final_statement] }).close_decision
      respond_to do |format|
        format.html { redirect_to @decision.path, notice: "Decision closed." }
        format.md { render_action_success({ action_name: 'close_decision', resource: @decision, result: "Decision closed." }) }
      end
    rescue StandardError => e
      respond_to do |format|
        format.html { redirect_to @decision.path, alert: e.message }
        format.md { render_action_error({ action_name: 'close_decision', resource: @decision, error: e.message }) }
      end
    end
  end

  def describe_update_final_statement
    render_action_description(ActionsHelper.action_description("update_final_statement", resource: current_decision))
  end

  def update_final_statement
    @decision = current_decision
    return render '404', status: 404 unless @decision
    return render 'shared/403', status: 403 unless @decision.can_edit_settings?(@current_user)

    unless @decision.closed?
      respond_to do |format|
        format.html { redirect_to @decision.path, alert: "Decision must be closed to set final statement." }
        format.md { render_action_error({ action_name: 'update_final_statement', resource: @decision, error: "Decision must be closed to set final statement." }) }
      end
      return
    end

    begin
      api_helper(params: { final_statement: params[:final_statement] }).update_final_statement
      respond_to do |format|
        format.html { redirect_to @decision.path, notice: "Final statement updated." }
        format.md { render_action_success({ action_name: 'update_final_statement', resource: @decision, result: "Final statement updated." }) }
      end
    rescue StandardError => e
      respond_to do |format|
        format.html { redirect_to @decision.path, alert: e.message }
        format.md { render_action_error({ action_name: 'update_final_statement', resource: @decision, error: e.message }) }
      end
    end
  end

  def describe_add_options
    render_action_description(ActionsHelper.action_description("add_options", resource: current_decision))
  end

  def describe_vote
    render_action_description(ActionsHelper.action_description("vote", resource: current_decision))
  end

  def describe_delete_decision
    render_action_description(ActionsHelper.action_description("delete_decision", resource: current_decision))
  end

  def execute_delete_decision
    @decision = current_decision
    return render '404', status: 404 unless @decision

    begin
      api_helper.delete_decision
      redirect_to(@current_collective.path || "/", notice: "Decision deleted.")
    rescue ActiveRecord::RecordInvalid
      render 'shared/403', status: :forbidden
    end
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

  def find_deleted_decision
    decision_id = params[:id] || params[:decision_id]
    return nil unless decision_id

    if decision_id.to_s.length == 8
      Decision.with_deleted.find_by(truncated_id: decision_id)
    else
      Decision.with_deleted.find_by(id: decision_id)
    end
  end
end
