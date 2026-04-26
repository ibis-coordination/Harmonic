# typed: false
require "test_helper"

class ChatMessagePresenterTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = User.create!(
      name: "Presenter Agent",
      email: "presenter-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    @chat_session = ChatSession.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )

    @task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: @ai_agent, initiated_by: @user,
      task: "Test", max_steps: 30, status: "completed",
      mode: "chat_turn", chat_session: @chat_session,
    )
  end

  test "formats agent message with content_html" do
    step = @task_run.agent_session_steps.create!(
      position: 0, step_type: "message",
      detail: { "content" => "Hello **human**!" }, sender: @ai_agent,
    )

    result = ChatMessagePresenter.format(step, @chat_session)

    assert_equal "message", result[:type]
    assert_equal step.id, result[:id]
    assert_equal @ai_agent.id, result[:sender_id]
    assert_equal @ai_agent.name, result[:sender_name]
    assert_equal "Hello **human**!", result[:content]
    assert_equal true, result[:is_agent]
    assert_not_nil result[:content_html]
    assert_includes result[:content_html], "<strong>human</strong>"
  end

  test "formats human message without content_html" do
    step = @task_run.agent_session_steps.create!(
      position: 0, step_type: "message",
      detail: { "content" => "Hello agent!" }, sender: @user,
    )

    result = ChatMessagePresenter.format(step, @chat_session)

    assert_equal @user.id, result[:sender_id]
    assert_equal @user.name, result[:sender_name]
    assert_equal "Hello agent!", result[:content]
    assert_equal false, result[:is_agent]
    assert_nil result[:content_html]
  end

  test "content_html sanitizes dangerous markup" do
    step = @task_run.agent_session_steps.create!(
      position: 0, step_type: "message",
      detail: { "content" => '<script>alert("xss")</script>Safe text' }, sender: @ai_agent,
    )

    result = ChatMessagePresenter.format(step, @chat_session)

    assert_not_includes result[:content_html], "<script>"
    assert_includes result[:content_html], "Safe text"
  end

  test "format output matches expected keys for ActionCable and polling" do
    step = @task_run.agent_session_steps.create!(
      position: 0, step_type: "message",
      detail: { "content" => "Test" }, sender: @ai_agent,
    )

    result = ChatMessagePresenter.format(step, @chat_session)
    expected_keys = %i[type id sender_id sender_name content content_html timestamp is_agent]

    assert_equal expected_keys.sort, result.keys.sort
  end
end
