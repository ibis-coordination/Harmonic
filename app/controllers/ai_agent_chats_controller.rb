# typed: false

class AiAgentChatsController < ApplicationController
  MAX_MESSAGE_LENGTH = 10_000

  before_action :require_human_user
  before_action :find_ai_agent

  # GET /ai-agents/:handle/chat
  def show
    @chat_session = active_chat_session
    @messages = @chat_session ? @chat_session.messages.includes(:sender) : []
    @page_title = "Chat - #{@ai_agent.display_name}"
  end

  # POST /ai-agents/:handle/chat
  def create
    # Reuse existing active session if one exists
    existing = active_chat_session
    if existing
      redirect_to ai_agent_chat_path(@ai_agent.handle)
      return
    end

    ChatSession.create!(
      tenant: current_tenant,
      ai_agent: @ai_agent,
      initiated_by: current_user,
    )

    redirect_to ai_agent_chat_path(@ai_agent.handle)
  end

  # POST /ai-agents/:handle/chat/message
  def send_message
    @chat_session = active_chat_session
    unless @chat_session
      head :not_found
      return
    end

    message_text = params[:message].to_s.strip.truncate(MAX_MESSAGE_LENGTH)
    if message_text.blank?
      render plain: "Message cannot be empty", status: :unprocessable_entity
      return
    end

    # If a turn is already running, attach the message to it (queued for next turn).
    # Otherwise, create a new task run and dispatch it.
    if turn_in_progress?
      task_run = @chat_session.task_runs.where(status: %w[queued running]).order(created_at: :desc).first!
      next_position = task_run.agent_session_steps.maximum(:position)&.+(1) || 0
      task_run.agent_session_steps.create!(
        position: next_position,
        step_type: "message",
        detail: { "content" => message_text },
        sender: current_user,
      )
    else
      task_run = create_chat_turn(message_text)
      task_run.agent_session_steps.create!(
        position: 0,
        step_type: "message",
        detail: { "content" => message_text },
        sender: current_user,
      )
      dispatch_chat_turn(task_run)
    end

    head :ok
  end

  # POST /ai-agents/:handle/chat/end
  def end_session
    @chat_session = active_chat_session
    if @chat_session
      # Cancel any in-progress turns
      @chat_session.task_runs.where(status: %w[queued running]).find_each do |run|
        run.update!(status: "cancelled", completed_at: Time.current)
      end
      @chat_session.update!(status: "ended")
    end

    redirect_to ai_agent_chat_path(@ai_agent.handle)
  end

  private

  def resource_model?
    false
  end

  def require_human_user
    return if current_user&.human?

    render status: :forbidden, plain: "403 Unauthorized"
  end

  def find_ai_agent
    @ai_agent = current_user&.ai_agents
      &.joins(:tenant_users)
      &.where(tenant_users: { tenant_id: current_tenant&.id, handle: params[:handle] })
      &.first

    render status: :not_found, plain: "404 Not Found" unless @ai_agent
  end

  def active_chat_session
    ChatSession.where(ai_agent: @ai_agent, initiated_by: current_user)
      .active
      .order(created_at: :desc)
      .first
  end

  def turn_in_progress?
    @chat_session.task_runs.where(status: %w[queued running]).exists?
  end

  def create_chat_turn(message_text)
    AiAgentTaskRun.create!(
      tenant: current_tenant,
      ai_agent: @ai_agent,
      initiated_by: current_user,
      task: message_text,
      max_steps: 30,
      status: "queued",
      mode: "chat_turn",
      chat_session: @chat_session,
      model: @ai_agent.agent_configuration&.dig("model") || "default",
    )
  end

  def dispatch_chat_turn(task_run)
    AgentRunnerDispatchService.dispatch(task_run)
  rescue StandardError => e
    Rails.logger.error("[AiAgentChats] Failed to dispatch chat turn #{task_run.id}: #{e.message}")
  end
end
