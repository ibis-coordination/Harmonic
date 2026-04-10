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

  # === Stripe billing tests ===

  test "new page redirects to billing when stripe_billing enabled and billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents/new"

    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "new page renders form when billing is set up" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents/new"

    assert_response :success
  end

  test "create redirects to billing when stripe_billing enabled and billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "New Agent", mode: "internal" }
    end

    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "create works normally when stripe_billing disabled" do
    # stripe_billing NOT enabled — should create agent as usual
    sign_in_as(@user, tenant: @tenant)

    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "New Agent", mode: "internal" }
    end

    assert_response :redirect
  end

  test "create works normally when billing is set up" do
    enable_stripe_billing_flag!(@tenant)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)

    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "New Agent", mode: "internal", confirm_billing: "1" }
    end

    assert_response :redirect
  end

  test "create assigns current user's stripe customer to new agent" do
    enable_stripe_billing_flag!(@tenant)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)

    post "/ai-agents/new/actions/create_ai_agent", params: { name: "Billing Agent", mode: "internal", confirm_billing: "1" }

    new_agent = User.where(user_type: "ai_agent").order(:created_at).last
    assert_equal sc.id, new_agent.stripe_customer_id
  end

  test "execute_create_ai_agent redirects to billing when not set up via markdown" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      post "/ai-agents/new/actions/create_ai_agent",
        params: { name: "New Agent", mode: "internal" },
        headers: { "Accept" => "text/markdown" }
    end

    # Application-level billing gate redirects to /billing before controller action runs
    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "create blocks agent creation for any request format when billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      post "/ai-agents/new/actions/create_ai_agent",
        params: { name: "New Agent", mode: "internal" },
        headers: { "Accept" => "application/json" }
    end

    # Should not return 200/success — billing gate must block all formats
    assert_includes [302, 403, 422], response.status
  end

  test "index redirects to billing when billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents"

    # Application-level billing gate redirects to /billing
    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "index does not show billing banner when billing is set up" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents"

    assert_response :success
    assert_not_includes response.body, "Billing required"
  end

  test "new redirects to billing when billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents/new"

    # Application-level billing gate redirects to /billing
    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "new shows creation form when billing is set up" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents/new"

    assert_response :success
    assert_not_includes response.body, "Billing required"
    assert_includes response.body, "pulse-form-input" # creation form should render
  end

  test "new shows creation form when stripe_billing flag is disabled" do
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents/new"

    assert_response :success
    assert_not_includes response.body, "Billing required"
    assert_includes response.body, "pulse-form-input"
  end

  test "execute_task redirects to billing when billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    # Set up billing initially to create the agent, then deactivate
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    @ai_agent.update!(stripe_customer_id: sc.id)
    sc.update!(active: false)

    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "AiAgentTaskRun.count" do
      post "/ai-agents/#{@ai_agent_handle}/run", params: { task: "Test task" }
    end

    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "update_settings blocked for archived agent" do
    enable_stripe_billing_flag!(@tenant)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)

    @ai_agent.tenant_user = @ai_agent.tenant_users.find_by(tenant_id: @tenant.id)
    @ai_agent.archive!

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { name: "Hacked Name" }

    assert_response :redirect
    @ai_agent.reload
    assert_not_equal "Hacked Name", @ai_agent.name
  end

  test "settings page links to billing for archived agent instead of reactivation form" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)

    @ai_agent.tenant_user = @ai_agent.tenant_users.find_by(tenant_id: @tenant.id)
    @ai_agent.archive!

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/settings"

    assert_response :success
    assert_includes response.body, "/billing"
    assert_not_includes response.body, "Reactivate Agent"
  end

  test "settings page links to billing for deactivation instead of form" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)

    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/settings"

    assert_response :success
    assert_includes response.body, "/billing"
    assert_not_includes response.body, "Deactivate Agent"
  end

  test "create rejects agent without billing confirmation when stripe_billing enabled" do
    enable_stripe_billing_flag!(@tenant)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "No Confirm Agent", mode: "internal" }
    end

    assert_response :redirect
    assert_match %r{/ai-agents/new}, response.location
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
