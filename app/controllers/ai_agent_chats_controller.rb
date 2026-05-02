# typed: false

class AiAgentChatsController < ApplicationController
  MAX_MESSAGE_LENGTH = 10_000

  before_action :require_human_user
  before_action :find_ai_agent
  before_action :find_chat_session, only: [:show, :send_message, :poll_messages]
  before_action :set_sidebar_mode, only: [:index, :show]
  before_action :load_chat_sessions, only: [:index, :show]

  # GET /ai-agents/:handle/chat
  def index
    @page_title = "Chat - #{@ai_agent.display_name}"
  end

  # POST /ai-agents/:handle/chat
  def create
    session = ChatSession.find_or_create_for(
      agent: @ai_agent,
      user: current_user,
      tenant: current_tenant,
    )

    redirect_to ai_agent_chat_path(@ai_agent.handle, session.id)
  end

  # GET /ai-agents/:handle/chat/:session_id
  def show
    @messages = @chat_session.messages.includes(:sender)
    @page_title = "Chat - #{@ai_agent.display_name}"
    @turn_running = @chat_session.task_runs.where(status: %w[queued running]).exists?
    check_agent_busy
  end

  # POST /ai-agents/:handle/chat/:session_id/message
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

    # If a turn is already running, attach the message to it (queued for next turn).
    # Otherwise, create a new task run and dispatch it.
    # Use a single query instead of check-then-act to avoid TOCTOU race
    # where a turn completes between the exists? check and the find.
    active_run = @chat_session.task_runs.where(status: %w[queued running]).order(created_at: :desc).first

    if active_run
      next_position = active_run.agent_session_steps.maximum(:position)&.+(1) || 0
      active_run.agent_session_steps.create!(
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
  # Polling endpoint — returns the same data format as ActionCable broadcasts,
  # plus turn status and latest activity for fallback transport.
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

    latest_turn = @chat_session.task_runs.order(created_at: :desc).first
    turn_status = latest_turn&.status
    # Only report meaningful statuses — "queued" and "running" both mean "running" to the UI
    turn_status = "running" if turn_status == "queued"
    # Only report status if there's actually something going on (not completed turns from long ago)
    turn_status = nil if turn_status == "completed"

    response_data = { messages: new_messages, turn_status: turn_status }
    response_data[:turn_error] = latest_turn&.error if turn_status == "failed"

    # Include latest activity text for running turns (only steps after setup).
    # Setup navigations (/whoami, saved path) always precede the first think step,
    # so we only show activity from steps positioned after the first think.
    if turn_status == "running" && latest_turn
      first_think_position = latest_turn.agent_session_steps.where(step_type: "think").minimum(:position)
      if first_think_position
        latest_activity_step = latest_turn.agent_session_steps
          .where(step_type: %w[navigate execute])
          .where("position > ?", first_think_position)
          .order(position: :desc)
          .first
        response_data[:activity] = format_activity_text(latest_activity_step) if latest_activity_step
      end
    end

    render json: response_data
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
    @sidebar_mode = "chat"
  end

  def load_chat_sessions
    @chat_sessions = ChatSession.where(ai_agent: @ai_agent, initiated_by: current_user)
      .order(created_at: :desc)
    # Pre-load first message per session to avoid N+1 in sidebar
    preload_first_messages
  end

  def preload_first_messages
    session_ids = @chat_sessions.map(&:id)
    return @first_messages = {} if session_ids.empty?

    # Get the earliest task run per session (the one containing the first message).
    # Use MIN(created_at) since MIN(uuid) is not supported in PostgreSQL.
    earliest_times = AiAgentTaskRun
      .where(chat_session_id: session_ids)
      .group(:chat_session_id)
      .minimum(:created_at)

    return @first_messages = {} if earliest_times.empty?

    first_runs = AiAgentTaskRun
      .where(chat_session_id: earliest_times.keys)
      .where(created_at: earliest_times.values)
      .pluck(:id, :chat_session_id)

    run_to_session = first_runs.to_h { |run_id, session_id| [run_id, session_id] }

    # Get only the first message step from each of those runs
    steps = AgentSessionStep
      .where(ai_agent_task_run_id: run_to_session.keys, step_type: "message")
      .order(:created_at, :position)

    @first_messages = {}
    steps.each do |step|
      session_id = run_to_session[step.ai_agent_task_run_id]
      @first_messages[session_id] ||= step
    end
  end

  def check_agent_busy
    # where.not with a non-nil value excludes NULLs in SQL, so we need to
    # explicitly include NULL chat_session_id (regular task runs).
    @agent_busy_run = AiAgentTaskRun
      .where(ai_agent: @ai_agent, status: %w[queued running])
      .where("chat_session_id IS DISTINCT FROM ?", @chat_session.id)
      .order(created_at: :desc)
      .first
  end
end
