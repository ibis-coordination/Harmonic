# frozen_string_literal: true

require "test_helper"

class AiAgentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    # Enable AI agents for this tenant
    @tenant.set_feature_flag!("ai_agents", true)

    # Create an AI agent for tests
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = create_ai_agent(parent: @user, name: "Test AI Agent")
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)

    @ai_agent_handle = @ai_agent.tenant_users.find_by(tenant: @tenant).handle

    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === Index Tests ===

  test "authenticated human user can access AI agents index" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
  end

  test "unauthenticated user is redirected from AI agents index" do
    get "/ai-agents"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "AI agent user cannot access AI agents index" do
    # AI agents use API tokens, not session auth, so they get redirected to login
    sign_in_as(@ai_agent, tenant: @tenant)
    get "/ai-agents"
    assert_response :redirect
  end

  test "index shows AI agents owned by current user" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
    assert_match @ai_agent.name, response.body
  end

  test "index handles AI agents with task runs" do
    # Create a task run for the AI agent
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
    )
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
  end

  test "index limits task runs query to prevent unbounded results" do
    # Create many task runs
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    15.times do |i|
      AiAgentTaskRun.create!(
        tenant: @tenant,
        ai_agent: @ai_agent,
        initiated_by: @user,
        task: "Test task #{i}",
        max_steps: 10,
        status: "completed",
      )
    end
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
  end

  # === Feature Flag Tests ===

  test "index returns forbidden when AI agents feature is disabled" do
    @tenant.set_feature_flag!("ai_agents", false)
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :forbidden
  end

  # === Run Task Tests ===

  test "authenticated human user can access run task form" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/run"
    assert_response :success
  end

  test "unauthenticated user is redirected from run task form" do
    get "/ai-agents/#{@ai_agent_handle}/run"
    assert_response :redirect
  end

  test "AI agent user cannot access run task form" do
    # AI agents use API tokens, not session auth, so they get redirected to login
    sign_in_as(@ai_agent, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/run"
    assert_response :redirect
  end

  test "run task returns 404 for non-existent AI agent" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/non-existent-handle/run"
    assert_response :not_found
  end

  # === Execute Task Tests ===

  test "authenticated human user can execute a task" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { AiAgentTaskRun.count }, 1 do
      post "/ai-agents/#{@ai_agent_handle}/run", params: { task: "Test task execution" }
    end

    assert_response :redirect
  end

  test "execute task with custom max_steps" do
    sign_in_as(@user, tenant: @tenant)

    post "/ai-agents/#{@ai_agent_handle}/run", params: {
      task: "Test task with custom steps",
      max_steps: 15,
    }

    task_run = AiAgentTaskRun.last
    assert_equal 15, task_run.max_steps
    assert_response :redirect
  end

  test "AI agent user cannot execute a task" do
    # AI agents use API tokens, not session auth, so they get redirected to login
    sign_in_as(@ai_agent, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/run", params: { task: "Test task" }
    assert_response :redirect
  end

  # === Runs List Tests ===

  test "authenticated human user can view runs list" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs"
    assert_response :success
  end

  test "AI agent user cannot view runs list" do
    # AI agents use API tokens, not session auth, so they get redirected to login
    sign_in_as(@ai_agent, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs"
    assert_response :redirect
  end

  # === Show Run Tests ===

  test "authenticated human user can view a specific run" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
    )
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}"
    assert_response :success
  end

  test "show run returns 404 for non-existent run" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs/00000000-0000-0000-0000-000000000000"
    assert_response :not_found
  end

  test "show run returns JSON format" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
    )
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}", headers: { "Accept" => "application/json" }
    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal "completed", json_response["status"]
  end

  # === Cancel Run Tests ===

  test "authenticated human user can cancel a queued run" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "queued",
    )
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}/cancel"

    task_run.reload
    assert_equal "cancelled", task_run.status
    assert_response :redirect
  end

  test "authenticated human user can cancel a running task" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "running",
    )
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}/cancel"

    task_run.reload
    assert_equal "cancelled", task_run.status
  end

  test "cannot cancel a completed run" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
    )
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}/cancel"

    task_run.reload
    assert_equal "completed", task_run.status
    assert_response :redirect
  end

  test "AI agent user cannot cancel a run" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "queued",
    )
    Tenant.clear_thread_scope

    # AI agents use API tokens, not session auth, so they get redirected to login
    sign_in_as(@ai_agent, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}/cancel"
    assert_response :redirect
  end

  # === Authorization Tests - Non-Parent User ===

  test "non-parent user cannot access another user's AI agent run task form" do
    other_user = create_user(email: "other-user-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/run"
    assert_response :not_found
  end

  test "non-parent user cannot execute task on another user's AI agent" do
    other_user = create_user(email: "other-user-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/run", params: { task: "Test task" }
    assert_response :not_found
  end

  test "non-parent user cannot view another user's AI agent runs" do
    other_user = create_user(email: "other-user-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs"
    assert_response :not_found
  end

  test "non-parent user cannot view another user's AI agent specific run" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed",
    )
    Tenant.clear_thread_scope

    other_user = create_user(email: "other-user-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}"
    assert_response :not_found
  end

  test "non-parent user cannot cancel another user's AI agent run" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "queued",
    )
    Tenant.clear_thread_scope

    other_user = create_user(email: "other-user-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/runs/#{task_run.id}/cancel"
    assert_response :not_found

    # Verify run was not cancelled
    task_run.reload
    assert_equal "queued", task_run.status
  end

  test "index does not show AI agents owned by other users" do
    other_user = create_user(email: "other-user-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
    assert_no_match @ai_agent.name, response.body
  end

  # === New AI Agent Tests ===

  test "authenticated human user can access new AI agent form" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/new"
    assert_response :success
  end

  test "AI agent user cannot access new AI agent form" do
    # AI agents use API tokens, not session auth, so they get redirected to login
    sign_in_as(@ai_agent, tenant: @tenant)
    get "/ai-agents/new"
    assert_response :redirect
  end
end
