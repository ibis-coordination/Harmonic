require "test_helper"

class AiAgentTaskRunAccessTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @parent = @global_user
    @tenant.enable_feature_flag!("ai_agents")

    @ai_agent = create_ai_agent_for(@parent, "My AiAgent")
    @other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(@other_parent)
    @collective.add_user!(@other_parent)
    @other_ai_agent = create_ai_agent_for(@other_parent, "Other AiAgent")
    @other_task_run = create_task_run(@other_ai_agent, @other_parent)

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  private

  def create_ai_agent_for(parent, name)
    ai_agent = create_ai_agent(parent: parent, name: name)
    @tenant.add_user!(ai_agent)
    @collective.add_user!(ai_agent)
    ai_agent
  end

  def create_task_run(ai_agent, initiated_by, task: "Test task")
    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: ai_agent,
      initiated_by: initiated_by,
      task: task,
      max_steps: AiAgentTaskRun::DEFAULT_MAX_STEPS,
      status: "completed",
      success: true,
      final_message: "Completed",
      started_at: 1.minute.ago,
      completed_at: Time.current
    )
  end

  # ====================
  # Task Run Show Page Access
  # ====================

  test "parent can access their own ai_agent's task run page" do
    task_run = create_task_run(@ai_agent, @parent)
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@ai_agent.handle}/runs/#{task_run.id}"

    assert_response :success
  end

  test "parent cannot access another user's ai_agent's task run page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@other_ai_agent.handle}/runs/#{@other_task_run.id}"

    assert_response :not_found
  end

  test "parent cannot access task run page with correct ai_agent handle but wrong run" do
    # Try to access other_task_run but using own ai_agent's handle
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@ai_agent.handle}/runs/#{@other_task_run.id}"

    assert_response :not_found
  end

  # ====================
  # Task Runs List Page Access
  # ====================

  test "parent can access their own ai_agent's runs list" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@ai_agent.handle}/runs"

    assert_response :success
  end

  test "parent cannot access another user's ai_agent's runs list" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@other_ai_agent.handle}/runs"

    assert_response :not_found
  end

  # ====================
  # Run Task Page Access
  # ====================

  test "parent can access their own ai_agent's run task page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@ai_agent.handle}/run"

    assert_response :success
  end

  test "parent cannot access another user's ai_agent's run task page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@other_ai_agent.handle}/run"

    assert_response :not_found
  end

  # ====================
  # AiAgents Index Page
  # ====================

  test "parent can access ai_agents index page" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents"

    assert_response :success
    # Should only see their own ai_agent, not other parent's ai_agent
    assert_match @ai_agent.name, response.body
    assert_no_match(/#{@other_ai_agent.name}/, response.body)
  end

  test "ai_agent cannot access ai_agents index page" do
    # Create API token for ai_agent
    token = ApiToken.create!(
      user: @ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now
    )

    get "/ai-agents", headers: { "Authorization" => "Bearer #{token.plaintext_token}" }

    assert_response :forbidden
  end

  # ====================
  # Edge Cases
  # ====================

  test "unauthenticated user cannot access task run pages" do
    get "/ai-agents/#{@ai_agent.handle}/runs/#{@other_task_run.id}"

    assert_response :redirect
  end

  test "accessing non-existent ai_agent returns not found" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/nonexistent-handle/runs"

    assert_response :not_found
  end

  test "accessing non-existent task run returns not found" do
    sign_in_as(@parent, tenant: @tenant)

    get "/ai-agents/#{@ai_agent.handle}/runs/nonexistent-id"

    assert_response :not_found
  end
end
