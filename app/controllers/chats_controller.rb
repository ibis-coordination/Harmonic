# typed: false

class ChatsController < ApplicationController
  MAX_MESSAGE_LENGTH = 10_000
  MESSAGES_PER_PAGE = 50

  before_action :require_human_user
  before_action :load_agents, only: [:index, :show]
  before_action :find_agent_and_session, only: [:show, :send_message, :poll_messages]
  before_action :set_sidebar_mode, only: [:index, :show]

  # GET /chat
  def index
    @page_title = "Chat"
  end

  # GET /chat/:handle
  def show
    @messages = @chat_session.messages
      .includes(:sender)
      .reorder(created_at: :desc)
      .limit(MESSAGES_PER_PAGE + 1)
      .to_a

    @has_older_messages = @messages.size > MESSAGES_PER_PAGE
    @messages = @messages.first(MESSAGES_PER_PAGE).reverse

    @oldest_message_timestamp = @messages.first&.created_at&.iso8601
    @page_title = "Chat - #{@ai_agent.display_name}"
    @turn_running = @chat_session.task_runs.exists?(status: ["queued", "running"])
    check_agent_busy
  end

  # POST /chat/:handle/message
  def send_message
    if @ai_agent.external_ai_agent?
      render plain: "External agents use API tokens, not chat", status: :unprocessable_entity
      return
    end

    message_text = params[:message].to_s.strip.truncate(MAX_MESSAGE_LENGTH)
    if message_text.blank?
      render plain: "Message cannot be empty", status: :unprocessable_entity
      return
    end

    active_run = @chat_session.task_runs.where(status: ["queued", "running"]).order(created_at: :desc).first

    if active_run
      next_position = active_run.agent_session_steps.maximum(:position)&.+(1) || 0
      active_run.agent_session_steps.create!(
        position: next_position,
        step_type: "message",
        detail: { "content" => message_text },
        sender: current_user
      )
    else
      task_run = create_chat_turn(message_text)
      task_run.agent_session_steps.create!(
        position: 0,
        step_type: "message",
        detail: { "content" => message_text },
        sender: current_user
      )
      dispatch_chat_turn(task_run)
    end

    head :ok
  end

  # GET /chat/:handle/messages?after=<iso8601>&before=<iso8601>
  def poll_messages
    if params[:before].present?
      render_older_messages
    else
      render_new_messages
    end
  end

  private

  def resource_model?
    false
  end

  def require_human_user
    return if current_user&.human?

    render status: :forbidden, plain: "403 Unauthorized"
  end

  def load_agents
    @agents = current_user&.ai_agents
      &.includes(:tenant_users)
      &.joins(:tenant_users)
      &.where(tenant_users: { tenant_id: current_tenant&.id, archived_at: nil })
      &.where(suspended_at: nil)
      &.order(:name) || []
  end

  def find_agent_and_session
    @ai_agent = current_user&.ai_agents
      &.joins(:tenant_users)
      &.where(tenant_users: { tenant_id: current_tenant&.id, handle: params[:handle] })
      &.first

    unless @ai_agent
      render status: :not_found, plain: "404 Not Found"
      return
    end

    @chat_session = ChatSession.find_or_create_for(
      agent: @ai_agent,
      user: current_user,
      tenant: current_tenant
    )
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
      model: @ai_agent.agent_configuration&.dig("model") || "default"
    )
  end

  def dispatch_chat_turn(task_run)
    AgentRunnerDispatchService.dispatch(task_run)
  rescue StandardError => e
    Rails.logger.error("[Chats] Failed to dispatch chat turn #{task_run.id}: #{e.message}")
  end

  def format_activity_text(step)
    case step.step_type
    when "navigate"
      path = step.detail&.dig("path")
      "Navigating to #{path}" if path.present?
    when "execute"
      action = step.detail&.dig("action")
      "Executing #{action}" if action.present?
    end
  end

  def set_sidebar_mode
    @sidebar_mode = "chat_unified"
  end

  def check_agent_busy
    @agent_busy_run = AiAgentTaskRun
      .where(ai_agent: @ai_agent, status: ["queued", "running"])
      .where("chat_session_id IS DISTINCT FROM ?", @chat_session.id)
      .order(created_at: :desc)
      .first
  end

  # Polling for new messages (after a timestamp)
  def render_new_messages
    after = begin
      params[:after].present? ? Time.zone.parse(params[:after]) : Time.zone.at(0)
    rescue ArgumentError
      Time.zone.at(0)
    end

    new_messages = @chat_session.messages
      .where("created_at > ?", after)
      .includes(:sender)
      .map { |step| ChatMessagePresenter.format(step, @chat_session) }

    latest_turn = @chat_session.task_runs.order(created_at: :desc).first
    turn_status = latest_turn&.status
    turn_status = "running" if turn_status == "queued"
    turn_status = nil if turn_status == "completed"

    response_data = { messages: new_messages, turn_status: turn_status }
    response_data[:turn_error] = latest_turn&.error if turn_status == "failed"

    if turn_status == "running" && latest_turn
      first_think_position = latest_turn.agent_session_steps.where(step_type: "think").minimum(:position)
      if first_think_position
        latest_activity_step = latest_turn.agent_session_steps
          .where(step_type: ["navigate", "execute"])
          .where("position > ?", first_think_position)
          .order(position: :desc)
          .first
        response_data[:activity] = format_activity_text(latest_activity_step) if latest_activity_step
      end
    end

    render json: response_data
  end

  # Fetching older messages (before a timestamp) for pagination
  def render_older_messages
    before = begin
      Time.zone.parse(params[:before])
    rescue ArgumentError
      Time.current
    end

    older = @chat_session.messages
      .where(created_at: ...before)
      .includes(:sender)
      .reorder(created_at: :desc)
      .limit(MESSAGES_PER_PAGE + 1)
      .to_a

    has_more = older.size > MESSAGES_PER_PAGE
    older = older.first(MESSAGES_PER_PAGE).reverse

    messages = older.map { |step| ChatMessagePresenter.format(step, @chat_session) }

    render json: { messages: messages, has_more: has_more }
  end
end
