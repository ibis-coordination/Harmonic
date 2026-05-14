# typed: false

# Renders the dedicated /trio chat page. Trio is an ordinary internal
# ai_agent User (system_role: "trio") that lives in every tenant; this
# controller just opens a ChatSession between the current user and the
# tenant's trio user, then renders the standard chat UI with trio-specific
# (trefoil-logo) branding.
class TrioController < ApplicationController
  MESSAGES_PER_PAGE = 50

  before_action :require_trio_enabled
  before_action :set_sidebar_mode, only: [:index]

  def index
    @page_title = "Trio"
    @partner = TrioSeeder.ensure_for(@current_tenant)
    @chat_session = ChatSession.find_or_create_between(
      user_a: @current_user,
      user_b: @partner,
      tenant: @current_tenant,
    )

    # Same context-switch the chat controller does so message creation and
    # event tracking land in the chat session's private collective.
    Collective.set_thread_context(@chat_session.collective)

    @messages = @chat_session.messages
      .includes(:sender)
      .reorder(created_at: :desc)
      .limit(MESSAGES_PER_PAGE + 1)
      .to_a
    @has_older_messages = @messages.size > MESSAGES_PER_PAGE
    @messages = @messages.first(MESSAGES_PER_PAGE).reverse
    @oldest_message_timestamp = @messages.first&.created_at&.iso8601
    @turn_running = @chat_session.task_runs.exists?(status: ["queued", "running"])
  end

  private

  def resource_model?
    false
  end

  def set_sidebar_mode
    @sidebar_mode = 'none'
  end

  def require_trio_enabled
    return if @current_tenant&.trio_enabled?

    @sidebar_mode = 'none'
    render "shared/403", status: :forbidden
  end
end
