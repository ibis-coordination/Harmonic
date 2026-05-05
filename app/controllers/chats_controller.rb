# typed: false

class ChatsController < ApplicationController
  MAX_MESSAGE_LENGTH = 10_000
  MESSAGES_PER_PAGE = 50

  before_action :find_partner_and_session, only: [:show, :send_message, :poll_messages, :actions_index, :describe_send_message, :execute_send_message]
  before_action :load_chat_partners, only: [:index, :show]
  before_action :set_sidebar_mode, only: [:index, :show]

  # GET /chat
  def index
    @page_title = "Chat"
    respond_to do |format|
      format.html
      format.md
    end
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
    @page_title = "Chat - #{@partner.display_name}"
    @turn_running = @chat_session.task_runs.exists?(status: ["queued", "running"])
    check_agent_busy

    respond_to do |format|
      format.html
      format.md
    end
  end

  # POST /chat/:handle/message
  def send_message
    message_text = params[:message].to_s.strip.truncate(MAX_MESSAGE_LENGTH)
    if message_text.blank?
      render plain: "Message cannot be empty", status: :unprocessable_entity
      return
    end

    create_and_dispatch_message(message_text)
    head :ok
  end

  # GET /chat/:handle/actions
  def actions_index
    render_actions_index(ActionsHelper.actions_for_route("/chat/:handle"))
  end

  # GET /chat/:handle/actions/send_message
  def describe_send_message
    render_action_description(ActionsHelper.action_description("send_message"))
  end

  # POST /chat/:handle/actions/send_message
  def execute_send_message
    message_text = params[:message].to_s.strip.truncate(MAX_MESSAGE_LENGTH)
    if message_text.blank?
      return render_action_error({
        action_name: "send_message",
        error: "Message cannot be empty",
      })
    end

    create_and_dispatch_message(message_text)
    render_action_success({
      action_name: "send_message",
      result: "Message sent.",
    })
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

  # Load chat partners for the sidebar.
  # Humans see: their agents + humans they have existing chat sessions with
  # Agents see: humans they have existing sessions with
  #
  # Sorted by most recent message (descending), then contacts without
  # messages last (alphabetically).
  def load_chat_partners
    if current_user&.ai_agent?
      partners = ChatSession.unscope_collective
        .where("user_one_id = ? OR user_two_id = ?", current_user.id, current_user.id)
        .map { |s| s.other_participant(current_user) }
        .reject(&:collective_identity?)
        .uniq

      # Filter out partners with an active block in either direction
      blocked_ids = blocked_partner_ids(partners.map(&:id))
      partners = partners.reject { |u| blocked_ids.include?(u.id) }
    else
      agents = current_user&.ai_agents
        &.includes(:tenant_users)
        &.joins(:tenant_users)
        &.where(tenant_users: { tenant_id: current_tenant&.id, archived_at: nil })
        &.where(suspended_at: nil)
        &.to_a || []

      human_sessions = ChatSession.unscope_collective
        .where("user_one_id = ? OR user_two_id = ?", current_user&.id, current_user&.id)
        .map { |s| s.other_participant(current_user) }
        .reject { |u| u.ai_agent? || u.collective_identity? }

      seen_ids = Set.new(agents.map(&:id))
      humans = human_sessions.uniq(&:id).reject { |u| seen_ids.include?(u.id) || u.ai_agent? }

      # Filter out partners with an active block in either direction
      blocked_user_ids = blocked_partner_ids(humans.map(&:id))
      humans = humans.reject { |u| blocked_user_ids.include?(u.id) }

      partners = agents + humans
    end

    @chat_partners = sort_chat_partners(partners)
    load_unread_chat_handles
  end

  # Build a set of partner handles that have unread chat notifications,
  # so the sidebar can show an unread dot.
  def load_unread_chat_handles
    unread_urls = NotificationRecipient
      .joins(:notification)
      .where(user: current_user, tenant_id: current_tenant&.id, channel: "in_app")
      .where(dismissed_at: nil)
      .where(notifications: { notification_type: "chat_message" })
      .pluck("notifications.url")

    @unread_chat_handles = Set.new(unread_urls.map { |url| url&.delete_prefix("/chat/") })
  end

  # Sort partners by most recent message (descending), then contacts
  # without messages last (alphabetically).
  def sort_chat_partners(partners)
    return partners if partners.empty?

    partner_ids = partners.map(&:id)

    # Get the latest message timestamp per partner from their chat sessions
    sessions = ChatSession.unscope_collective
      .where("user_one_id = ? OR user_two_id = ?", current_user&.id, current_user&.id)
      .where("user_one_id IN (?) OR user_two_id IN (?)", partner_ids, partner_ids)

    latest_message_at = {}
    sessions.each do |s|
      other_id = s.user_one_id == current_user&.id ? s.user_two_id : s.user_one_id
      next unless partner_ids.include?(other_id)
      latest = s.chat_messages.unscope(where: :collective_id).maximum(:created_at)
      latest_message_at[other_id] = latest if latest
    end

    epoch = Time.at(0)
    partners.sort_by do |p|
      [
        latest_message_at[p.id] ? 0 : 1,        # contacts with messages before those without
        -(latest_message_at[p.id] || epoch).to_f, # most recent message first
        p.display_name.to_s.downcase,            # alphabetical tiebreaker
      ]
    end
  end

  # Find the other participant by handle and resolve the chat session.
  # After finding/creating the session, switches the thread context to the
  # chat session's collective so that message creation and event tracking
  # are scoped to the private chat collective.
  def find_partner_and_session
    @partner = User.joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant&.id, handle: params[:handle] })
      .first

    unless @partner
      render status: :not_found, plain: "404 Not Found"
      return
    end

    # Authorization: must be on same tenant (handled by query above)
    # For human→agent: must be the user's own agent
    if current_user.human? && @partner.ai_agent? && !current_user.ai_agents.include?(@partner)
      render status: :not_found, plain: "404 Not Found"
      return
    end

    # Block check: if either user has blocked the other, deny access
    if UserBlock.between?(current_user, @partner)
      render status: :forbidden, plain: "Chat is unavailable due to a block between you and this user."
      return
    end

    @chat_session = ChatSession.find_or_create_between(
      user_a: current_user,
      user_b: @partner,
      tenant: current_tenant,
    )

    # Switch collective context to the chat session's private collective.
    # This ensures all subsequent queries, message creation, and event
    # tracking are scoped to the chat collective (not the main collective).
    Collective.set_thread_context(@chat_session.collective)
  end

  def create_and_dispatch_message(message_text)
    chat_message = @chat_session.chat_messages.create!(
      sender: current_user,
      content: message_text,
    )

    # Broadcast to the other participant via ActionCable
    ChatSessionChannel.broadcast_to(
      @chat_session,
      ChatMessagePresenter.format(chat_message, @chat_session),
    )

    # Notify the recipient (upsert: one notification per sender)
    partner_handle = TenantUser.tenant_scoped_only(current_tenant.id).find_by(user: current_user)&.handle
    if partner_handle
      NotificationService.notify_chat_message!(
        sender: current_user,
        recipient: @partner,
        tenant: current_tenant,
        url: "/chat/#{partner_handle}",
      )
    end

    # Auto-dismiss any notification from the partner (we're replying)
    NotificationService.dismiss_chat_notifications_from!(
      user: current_user,
      sender: @partner,
      tenant: current_tenant,
    )

    # If the sender is human and the partner is an internal agent, dispatch a turn
    if current_user.human? && @partner.internal_ai_agent?
      unless @chat_session.task_runs.exists?(status: ["queued", "running"])
        task_run = create_chat_turn(message_text)
        dispatch_chat_turn(task_run)
      end
    end
  end

  def create_chat_turn(message_text)
    AiAgentTaskRun.create!(
      tenant: current_tenant,
      ai_agent: @partner,
      initiated_by: current_user,
      task: message_text,
      max_steps: 30,
      status: "queued",
      mode: "chat_turn",
      chat_session: @chat_session,
      model: @partner.agent_configuration&.dig("model") || "default",
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

  # Returns IDs of partners who have a block relationship with current_user
  def blocked_partner_ids(partner_ids)
    return Set.new if partner_ids.empty?

    UserBlock.where(blocker: current_user, blocked_id: partner_ids)
      .or(UserBlock.where(blocker_id: partner_ids, blocked: current_user))
      .pluck(:blocker_id, :blocked_id)
      .flatten
      .reject { |id| id == current_user&.id }
      .to_set
  end

  def set_sidebar_mode
    @sidebar_mode = "chat_unified"
  end

  def check_agent_busy
    return unless @partner.ai_agent?

    @agent_busy_run = AiAgentTaskRun
      .where(ai_agent: @partner, status: ["queued", "running"])
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
      .map { |msg| ChatMessagePresenter.format(msg, @chat_session) }

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

    messages = older.map { |msg| ChatMessagePresenter.format(msg, @chat_session) }

    render json: { messages: messages, has_more: has_more }
  end
end
