# frozen_string_literal: true

require "test_helper"

class AiAgentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    # Enable AI agents for this tenant
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)

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
    @tenant.set_feature_flag!("internal_ai_agents", false)
    @tenant.set_feature_flag!("external_ai_agents", false)
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

  test "execute_task is rate-limited per (user, agent)" do
    sign_in_as(@user, tenant: @tenant)

    Sidekiq.redis do |conn|
      keys = conn.keys("rate_limit:agent_task_runs:*")
      conn.del(*keys) if keys.any?
    end

    begin
      AiAgentsController::TASK_RUNS_PER_MINUTE.times do |i|
        post "/ai-agents/#{@ai_agent_handle}/run", params: { task: "Task #{i}" }
        assert_response :redirect, "Run #{i + 1} should succeed: #{response.status}"
      end

      post "/ai-agents/#{@ai_agent_handle}/run",
        params: { task: "Over limit" },
        headers: { "Accept" => "application/json" }
      assert_response :too_many_requests
    ensure
      Sidekiq.redis do |conn|
        keys = conn.keys("rate_limit:agent_task_runs:*")
        conn.del(*keys) if keys.any?
      end
    end
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
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
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
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)

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
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "No Confirm Agent", mode: "internal" }
    end

    assert_response :redirect
    assert_match %r{/ai-agents/new}, response.location
  end

  test "create does NOT require billing confirmation for app_admin (billing-exempt)" do
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    sign_in_as(@user, tenant: @tenant)

    # No confirm_billing param — admin should still be allowed through because
    # the billing UI is hidden from them and no Stripe charges apply.
    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "Admin Agent", mode: "internal" }
    end
    assert_response :redirect
    assert_no_match %r{/ai-agents/new\z}, response.location, "should not bounce back to the new form"
  ensure
    @user.update!(app_admin: false)
  end

  test "execute_create_ai_agent ignores system_role param" do
    # `system_role: "trio"` would grant billing exemption + workspace-membership
    # + reserved-handle privileges. Only TrioSeeder may assign it; user-supplied
    # params must not.
    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { User.where(user_type: "ai_agent").count }, 1 do
      post "/ai-agents/new/actions/create_ai_agent",
        params: { name: "Sneaky Agent", mode: "external", system_role: "trio" }
    end

    created = User.where(user_type: "ai_agent").order(created_at: :desc).first
    assert_nil created.system_role
    assert_equal @user.id, created.parent_id
  end

  test "update_settings cannot rename an agent's handle to the reserved 'trio'" do
    sign_in_as(@user, tenant: @tenant)
    begin
      post "/ai-agents/#{@ai_agent_handle}/settings", params: { new_handle: "trio" }
    rescue ActiveRecord::RecordInvalid
      # Expected — TenantUser validation rejects the reserved handle.
    end

    @ai_agent.tenant_users.find_by(tenant: @tenant).reload
    assert_equal @ai_agent_handle, @ai_agent.tenant_users.find_by(tenant: @tenant).handle
  end

  # === Split-flag scenario tests ===

  test "run_task is reachable when internal_ai_agents is enabled" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/run"
    assert_response :success
  end

  test "run_task returns 403 when internal_ai_agents is disabled even if external is enabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/run"
    assert_response :forbidden
  end

  test "run_task returns 404 for an external agent even with internal flag on" do
    @ai_agent.update_columns(agent_configuration: { "mode" => "external" })
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/run"
    assert_response :not_found
  end

  test "execute_task returns 404 for an external agent" do
    @ai_agent.update_columns(agent_configuration: { "mode" => "external" })
    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/run", params: { task: "x" }
    assert_response :not_found
  end

  test "settings is reachable when only external_ai_agents is enabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/settings"
    assert_response :success
  end

  test "settings is reachable when only internal_ai_agents is enabled" do
    @tenant.disable_feature_flag!("external_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/settings"
    assert_response :success
  end

  test "settings returns 403 when both flags are disabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.disable_feature_flag!("external_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/settings"
    assert_response :forbidden
  end

  test "create with mode=internal is blocked when internal_ai_agents is disabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Blocked Internal Agent",
      mode: "internal",
      confirm_billing: "1",
    }
    assert_response :forbidden
  end

  test "create with mode=external is blocked when external_ai_agents is disabled" do
    @tenant.disable_feature_flag!("external_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Blocked External Agent",
      mode: "external",
      confirm_billing: "1",
    }
    assert_response :forbidden
  end

  test "create with missing mode defaults to external and is blocked when external_ai_agents is disabled" do
    @tenant.disable_feature_flag!("external_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Blocked Default-mode Agent",
      confirm_billing: "1",
    }
    assert_response :forbidden
  end

  test "agent itself can read its own /ai-agents/handle/settings via authorize_parent_or_self" do
    @tenant.enable_api!
    token = ApiToken.create!(
      user: @ai_agent,
      tenant: @tenant,
      name: "Self-Read Token",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
    )
    get "/ai-agents/#{@ai_agent_handle}/settings",
      headers: {
        "Authorization" => "Bearer #{token.plaintext_token}",
        "Accept" => "text/markdown",
      }
    assert_response :success
  end

  test "non-parent, non-self user is 403 on settings" do
    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/settings"
    assert_response :forbidden
  end

  test "agent itself cannot POST update_settings" do
    token = ApiToken.create!(
      user: @ai_agent,
      tenant: @tenant,
      name: "Self-Write Token",
      scopes: ApiToken.write_scopes + ApiToken.read_scopes,
      expires_at: 1.year.from_now,
    )
    post "/ai-agents/#{@ai_agent_handle}/settings",
      params: { name: "Self-renamed" },
      headers: {
        "Authorization" => "Bearer #{token.plaintext_token}",
        "Accept" => "text/markdown",
      }
    assert_response :forbidden
  end

  # === External-only rollout (the production rollout config) ===
  #
  # This is the configuration external customers will see first: external AI
  # agents are enabled, internal (Task Runner) AI agents are not. These tests
  # exercise the human-facing UX flow end-to-end in that configuration to
  # catch any place where the UI assumes internal is on.

  test "external-only: index page is reachable and lists existing external agent" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @ai_agent.update_columns(agent_configuration: { "mode" => "external" })
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
    assert_includes response.body, @ai_agent.name
  end

  test "external-only: index empty-state copy mentions API access" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    # Ensure the parent user has no agents in this tenant so the empty state renders.
    @user.ai_agents.find_each { |a| destroy_user!(a) }
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
    assert_match(/No AI Agents Yet/, response.body)
    assert_match(/programmatic access to the API/, response.body)
  end

  test "external-only: per-agent action row hides Run Task/Runs/Automations but keeps Settings" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @ai_agent.update_columns(agent_configuration: { "mode" => "external" })
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents"
    assert_response :success
    refute_includes response.body, "Run Task"
    assert_includes response.body, "Settings"
    # External agents manage their notification webhook on settings — no
    # automations surface, no Automations button in the agent list.
    refute_includes response.body, "Automations"
  end

  test "external-only: show page is reachable and hides Run Task button" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @ai_agent.update_columns(agent_configuration: { "mode" => "external" })
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}"
    assert_response :success
    refute_includes response.body, ">Run Task"
  end

  test "external-only: new agent form is reachable" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/new"
    assert_response :success
  end

  test "external-only: new agent form hides Mode radio and sends hidden mode=external" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/new"
    assert_response :success
    refute_match(/radio_button.*mode/, response.body)
    refute_match(/<label[^>]*>\s*<input[^>]*type="radio"[^>]*name="mode"/, response.body)
    assert_match(/<input[^>]*type="hidden"[^>]*name="mode"[^>]*value="external"/, response.body)
  end

  test "create with name that produces an already-taken handle surfaces a friendly error, not a 500" do
    sign_in_as(@user, tenant: @tenant)
    existing = create_ai_agent(parent: @user, name: "Collision Target")
    existing_handle = @tenant.add_user!(existing).handle

    assert_no_difference -> { User.where(user_type: "ai_agent").count } do
      post "/ai-agents/new/actions/create_ai_agent", params: {
        name: existing_handle,
        mode: "external",
        confirm_billing: "1",
      }
    end

    assert_response :redirect, "should redirect back to the form, not 500"
    assert_match(/handle|already|taken|in use|different name/i, flash[:alert] || flash[:error] || flash[:notice] || "",
      "flash must explain why creation failed so the user can pick a different name")
    follow_redirect!
    # Use a key the layout renders. The layout renders :notice and :alert
    # (Rails convention). Pre-existing flash[:error] uses in this controller
    # are a separate UX bug — out of scope here.
    assert_match(/handle|already|taken|in use|different name/i, response.body,
      "flash should be visible in the rendered form so the user knows why it failed")
  end

  test "external-only: admin user creating an agent does NOT get pending_billing_setup even with inactive stripe_customer" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    # Pre-existing inactive stripe_customer (e.g. subscription was canceled or never activated)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_admin_test", active: false)

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Admin External Agent",
      mode: "external",
      generate_token: "1",
      confirm_billing: "1",
    }

    new_agent = @user.ai_agents.find_by(name: "Admin External Agent")
    assert new_agent
    refute new_agent.pending_billing_setup?,
      "admin-created agents should NOT be marked pending_billing_setup just because the admin's stripe_customer happens to be inactive — admins are billing-exempt"
  end

  test "external-only: regular user with inactive stripe_customer creating an agent DOES get pending_billing_setup" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    enable_stripe_billing_flag!(@tenant)
    # Clear pre-existing agents so the user passes the early
    # requires_stripe_billing? redirect (billable_quantity must be 0 going
    # into the request — otherwise they'd hit the early redirect, not the
    # pending-flag code path we're testing).
    @user.ai_agents.find_each { |a| destroy_user!(a) }
    StripeCustomer.create!(billable: @user, stripe_id: "cus_regular_test", active: false)

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Regular User External Agent",
      mode: "external",
      generate_token: "1",
      confirm_billing: "1",
    }

    new_agent = @user.ai_agents.find_by(name: "Regular User External Agent")
    assert new_agent
    assert new_agent.pending_billing_setup?,
      "non-admin user without an active subscription must have the new agent marked pending so the runner blocks it until billing is set up"
  end

  test "external-only: external agent creation with generate_token reveals plaintext token in response" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "External Agent With Token",
      mode: "external",
      generate_token: "1",
      confirm_billing: "1",
    }

    # PRG: redirect to the canonical agent show URL so the URL bar isn't
    # stuck on the POST endpoint. Plaintext rides through one flash round-trip.
    new_agent = @user.ai_agents.find_by(name: "External Agent With Token")
    assert new_agent
    new_agent_handle = TenantUser.find_by(tenant: @tenant, user: new_agent).handle
    assert_redirected_to "/ai-agents/#{new_agent_handle}"
    assert ApiToken.unscoped.where(user_id: new_agent.id).any?, "token should be persisted"

    follow_redirect!
    assert_response :success

    # Plaintext token is only available in-memory on the freshly created
    # ApiToken — hashed in the DB and never retrievable. After follow_redirect!,
    # the show page must have revealed it AND warned the user it's one-time.
    assert_match(/\b[a-f0-9]{40}\b/, response.body,
      "plaintext token (40-char hex) must appear in the response — it is hashed at rest and never retrievable")
    assert_match(/won't be able to see|will not be able to see/i, response.body,
      "must warn the user this is the only chance to copy the token")

    # Refreshing the show page (re-GET without the flash) must NOT re-reveal
    # the secret — flash is single-use, so a refresh-replay attack fails.
    get "/ai-agents/#{new_agent_handle}"
    assert_no_match(/\b[a-f0-9]{40}\b/, response.body,
      "refresh after reveal must not re-show the plaintext token")
  end

  test "external-only: external agent creation without generate_token redirects (no token rendered)" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "External Agent No Token",
      mode: "external",
      confirm_billing: "1",
    }
    assert_response :redirect
    new_agent = @user.ai_agents.find_by(name: "External Agent No Token")
    assert new_agent
    assert_empty ApiToken.unscoped.where(user_id: new_agent.id)
  end

  test "external-only: external agent creation succeeds via markdown action" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    assert_difference -> { @user.ai_agents.where(tenant_users: { tenant_id: @tenant.id }).joins(:tenant_users).count }, 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: {
        name: "External Only Agent",
        mode: "external",
        confirm_billing: "1",
      }
    end
    new_agent = @user.ai_agents.find_by(name: "External Only Agent")
    assert new_agent
    assert new_agent.external_ai_agent?, "agent should be external-mode"
  end

  test "external-only: create with no mode param succeeds (defaults to external)" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Default Mode Agent",
      confirm_billing: "1",
    }
    new_agent = @user.ai_agents.find_by(name: "Default Mode Agent")
    assert new_agent, "agent should be created"
    assert new_agent.external_ai_agent?, "agent should default to external mode"
  end

  test "external-only: runs index is gated (no UI surface for runs)" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/runs"
    assert_response :forbidden
  end

  test "external-only: any_ai_agents_enabled? is true so top nav AI Agents link renders" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_as(@user, tenant: @tenant)
    get "/"
    assert_match %r{href="/ai-agents"}, response.body, "Top nav AI Agents link should be visible"
  end

  test "update_settings accepts capabilities with sentinel and writes []" do
    sign_in_as(@user, tenant: @tenant)
    @ai_agent.update!(agent_configuration: @ai_agent.agent_configuration.to_h.merge("capabilities" => ["create_note"]))
    post "/ai-agents/#{@ai_agent_handle}/settings", params: {
      name: @ai_agent.name,
      capabilities: [""],
    }
    assert_response :redirect
    @ai_agent.reload
    assert_equal [], @ai_agent.agent_configuration["capabilities"]
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
