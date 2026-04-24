# typed: false

class AiAgentChatsController < ApplicationController
  MAX_MESSAGE_LENGTH = 10_000

  before_action :require_human_user
  before_action :find_ai_agent
  before_action :find_chat_session, only: [:show, :send_message, :poll_messages]

  # GET /ai-agents/:handle/chat
  def index
    @chat_sessions = ChatSession.where(ai_agent: @ai_agent, initiated_by: current_user)
      .order(created_at: :desc)
    @page_title = "Chat - #{@ai_agent.display_name}"
  end

  # POST /ai-agents/:handle/chat
  def create
    session = ChatSession.create!(
      tenant: current_tenant,
      ai_agent: @ai_agent,
      initiated_by: current_user,
    )

    redirect_to ai_agent_chat_path(@ai_agent.handle, session.id)
  end

  # GET /ai-agents/:handle/chat/:session_id
  def show
    @messages = @chat_session.messages.includes(:sender)
    @page_title = "Chat - #{@ai_agent.display_name}"
  end

  # POST /ai-agents/:handle/chat/:session_id/message
  def send_message
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

  # GET /ai-agents/:handle/chat/:session_id/messages?after=<iso8601>
  # Polling endpoint — returns the same data format as ActionCable broadcasts.
  def poll_messages
    after = begin
      params[:after].present? ? Time.parse(params[:after]) : Time.at(0)
    rescue ArgumentError
      Time.at(0)
    end

    new_messages = @chat_session.messages
      .where("created_at > ?", after)
      .includes(:sender)
      .map { |step| ChatMessagePresenter.format(step, @chat_session) }

    render json: { messages: new_messages }
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

  def find_chat_session
    @chat_session = ChatSession.find_by(
      id: params[:session_id],
      ai_agent: @ai_agent,
      initiated_by: current_user,
    )
    render status: :not_found, plain: "404 Not Found" unless @chat_session
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
