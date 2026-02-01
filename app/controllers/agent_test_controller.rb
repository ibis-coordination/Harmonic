# typed: false
# frozen_string_literal: true

# Test controller for observing AI agent behavior.
# This is a development tool for testing AgentNavigator.
class AgentTestController < ApplicationController
  layout "pulse"
  skip_before_action :verify_authenticity_token, only: [:run]

  def index
    @page_title = "Agent Test"
    @sidebar_mode = "none"
    @studios = current_tenant.superagents.order(:name)
    @current_superagent = current_superagent
    # Show all subagents the current user has created across all studios
    @agent_users = User.where(user_type: "subagent", parent_id: current_user.id)
  end

  def run
    @page_title = "Agent Result"
    @sidebar_mode = "none"

    # Find the starting studio (defaults to current studio)
    @starting_studio = if params[:studio_id].present?
                         current_tenant.superagents.find(params[:studio_id])
                       else
                         current_superagent
                       end

    # Find the agent (must be an existing subagent owned by current user)
    @agent_user = find_agent

    # Create the navigator
    navigator = AgentNavigator.new(
      user: @agent_user,
      tenant: current_tenant,
      superagent: @starting_studio
    )

    # Run the agent
    @result = navigator.run(
      task: params[:task],
      max_steps: (params[:max_steps] || 15).to_i
    )

    respond_to do |format|
      format.html { render :result }
      format.json { render json: serialize_result(@result) }
    end
  end

  private

  def find_agent
    # Only allow using existing subagents that the current user owns
    agent_id = params[:agent_id]
    raise ActionController::BadRequest, "Agent is required" if agent_id.blank?

    agent = User.find_by(id: agent_id, user_type: "subagent", parent_id: current_user.id)
    raise ActiveRecord::RecordNotFound, "Agent not found or not owned by you" unless agent

    agent
  end

  def serialize_result(result)
    {
      success: result.success,
      final_message: result.final_message,
      error: result.error,
      steps: result.steps.map do |step|
        {
          type: step.type,
          detail: step.detail,
          timestamp: step.timestamp.iso8601,
        }
      end,
    }
  end
end
