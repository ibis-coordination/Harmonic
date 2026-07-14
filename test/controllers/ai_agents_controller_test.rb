# frozen_string_literal: true

require "test_helper"

class AiAgentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

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

    # Keep model-price lookups from reaching Stripe during form renders. Tests
    # that exercise pricing stub GatewayModelCatalog.prices directly; everything
    # else should see an unconfigured catalog (empty), not the ambient .env value.
    @original_pricing_plan_id = ENV.delete("STRIPE_PRICING_PLAN_ID")
  end

  teardown do
    ENV["STRIPE_PRICING_PLAN_ID"] = @original_pricing_plan_id if @original_pricing_plan_id
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
    AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "completed"
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
        status: "completed"
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
      status: "completed"
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
      status: "completed"
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
      status: "queued"
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
      status: "running"
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
      status: "completed"
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
      status: "queued"
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
      status: "completed"
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
      status: "queued"
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
    sign_in_with_ai_agents_reverify(@user)
    get "/ai-agents/new"
    assert_response :success
  end

  test "new agent form shows per-model prices when billing is on" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_pricing_ok", stripe_subscription_id: "sub_pricing_ok", active: true)
    sign_in_with_ai_agents_reverify(@user)

    catalog = { "anthropic/claude-sonnet-4.6" => { input_per_million: "3.90", output_per_million: "19.50" } }
    StripeService.stub(:preview_proration, 0) do
      GatewayModelCatalog.stub(:prices, catalog) do
        get "/ai-agents/new"
      end
    end

    assert_response :success
    assert_includes response.body, "Priced per 1 million tokens"
    assert_includes response.body, "$3.90"
    assert_includes response.body, "$19.50"
  end

  test "new agent form omits per-model prices when billing is off" do
    sign_in_with_ai_agents_reverify(@user)

    catalog = { "anthropic/claude-sonnet-4.6" => { input_per_million: "3.90", output_per_million: "19.50" } }
    GatewayModelCatalog.stub(:prices, catalog) do
      get "/ai-agents/new"
    end

    assert_response :success
    assert_not_includes response.body, "Priced per 1 million tokens"
    assert_not_includes response.body, "$3.90"
  end

  test "new AI agent form renders notification toggles (single on/off per type)" do
    sign_in_with_ai_agents_reverify(@user)
    get "/ai-agents/new"

    assert_response :success
    assert_includes response.body, "Notification preferences"
    assert_includes response.body, "notifications[comment][in_app]"
    assert_not_includes response.body, "notifications[comment][email]"
  end

  test "create applies notification toggles from the new-agent form" do
    sign_in_with_ai_agents_reverify(@user)

    post "/ai-agents/new/actions/create_ai_agent",
         params: { name: "Notif Agent", mode: "internal", notifications_present: "1",
                   notifications: { comment: { in_app: "true" } } }

    assert_response :redirect
    agent = @user.ai_agents.find_by!(name: "Notif Agent")
    tu = agent.tenant_users.find_by(tenant: @tenant)
    assert tu.notification_enabled?("comment", "in_app"), "checked toggle on"
    refute tu.notification_enabled?("mention", "in_app"), "unchecked toggle off"
    refute tu.notification_enabled?("comment", "email"), "agents never get email"
  end

  test "AI agent user cannot access new AI agent form" do
    # AI agents use API tokens, not session auth, so they get redirected to login
    sign_in_as(@ai_agent, tenant: @tenant)
    get "/ai-agents/new"
    assert_response :redirect
  end

  # === Stripe billing tests ===

  test "execute_task does not bounce a free-account principal with credits to billing" do
    # An app admin owes no per-identity fee, so their customer's active flag
    # is legitimately false — the run-task gate must mirror dispatch's
    # free-principal carve-out instead of bouncing them to /billing. The
    # agent is deliberately unstamped: the principal's own customer funds it.
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_free_run",
      active: false,
      pricing_plan_subscription_id: "bpps_free_run",
    )
    sign_in_as(@user, tenant: @tenant)

    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      post "/ai-agents/#{@ai_agent_handle}/run", params: { task: "say hello" }
    end

    assert_response :redirect
    assert_no_match %r{/billing}, response.location, "free-account principal with credits must not be bounced to billing"
  ensure
    @user.update!(app_admin: false)
    @user.reload.stripe_customer&.destroy
  end

  test "new page redirects to billing when stripe_billing enabled and billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_with_ai_agents_reverify(@user)

    get "/ai-agents/new"

    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "new page renders form when billing is set up" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_with_ai_agents_reverify(@user)

    get "/ai-agents/new"

    assert_response :success
  end

  test "create redirects to billing when stripe_billing enabled and billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_with_ai_agents_reverify(@user)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "New Agent", mode: "internal" }
    end

    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "create works normally when stripe_billing disabled" do
    # stripe_billing NOT enabled — should create agent as usual
    sign_in_with_ai_agents_reverify(@user)

    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "New Agent", mode: "internal" }
    end

    assert_response :redirect
  end

  test "create works normally when billing is set up" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_with_ai_agents_reverify(@user)

    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "New Agent", mode: "internal", confirm_billing: "1" }
    end

    assert_response :redirect
  end

  test "create assigns current user's stripe customer to new agent" do
    enable_stripe_billing_flag!(@tenant)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_with_ai_agents_reverify(@user)

    post "/ai-agents/new/actions/create_ai_agent", params: { name: "Billing Agent", mode: "internal", confirm_billing: "1" }

    new_agent = User.where(user_type: "ai_agent").order(:created_at).last
    assert_equal sc.id, new_agent.stripe_customer_id
  end

  test "execute_create_ai_agent redirects to billing when not set up via markdown" do
    enable_stripe_billing_flag!(@tenant)
    sign_in_with_ai_agents_reverify(@user)

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
    sign_in_with_ai_agents_reverify(@user)

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
    sign_in_with_ai_agents_reverify(@user)

    get "/ai-agents/new"

    # Application-level billing gate redirects to /billing
    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "new shows creation form when billing is set up" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_with_ai_agents_reverify(@user)

    get "/ai-agents/new"

    assert_response :success
    assert_not_includes response.body, "Billing required"
    assert_includes response.body, "pulse-form-input" # creation form should render
  end

  test "new shows creation form when stripe_billing flag is disabled" do
    sign_in_with_ai_agents_reverify(@user)

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

  test "update_settings persists allow_public_writes when the box is checked" do
    sign_in_as(@user, tenant: @tenant)
    # The form posts "1" when the checkbox is checked.
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { allow_public_writes: "1" }

    assert_response :redirect
    @ai_agent.reload
    assert_equal true, @ai_agent.agent_configuration["allow_public_writes"]
  end

  test "update_settings stores allow_public_writes false on the hidden-sentinel-only submit" do
    @ai_agent.update!(agent_configuration: (@ai_agent.agent_configuration || {}).merge("allow_public_writes" => true))

    sign_in_as(@user, tenant: @tenant)
    # An unchecked box posts only the hidden sentinel "0".
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { allow_public_writes: "0" }

    assert_response :redirect
    @ai_agent.reload
    assert_equal false, @ai_agent.agent_configuration["allow_public_writes"]
  end

  test "update_settings leaves allow_public_writes untouched when the param is absent" do
    @ai_agent.update!(agent_configuration: (@ai_agent.agent_configuration || {}).merge("allow_public_writes" => true))

    sign_in_as(@user, tenant: @tenant)
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { name: "Renamed" }

    assert_response :redirect
    @ai_agent.reload
    assert_equal true, @ai_agent.agent_configuration["allow_public_writes"]
  end

  test "update_settings sets, keeps, and clears the daily LLM spend cap" do
    sign_in_as(@user, tenant: @tenant)

    # Dollars in the form, cents in the column.
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { llm_daily_spend_cap: "5.50" }
    assert_response :redirect
    assert_equal 550, @ai_agent.reload.llm_daily_spend_cap_cents

    # Absent param leaves it untouched.
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { name: "Renamed" }
    assert_equal 550, @ai_agent.reload.llm_daily_spend_cap_cents

    # Blank clears it.
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { llm_daily_spend_cap: "" }
    assert_nil @ai_agent.reload.llm_daily_spend_cap_cents
  end

  test "update_settings rejects an unparseable spend cap with a friendly error" do
    @ai_agent.update!(llm_daily_spend_cap_cents: 550)
    sign_in_as(@user, tenant: @tenant)

    post "/ai-agents/#{@ai_agent_handle}/settings", params: { llm_daily_spend_cap: "lots" }

    assert_response :redirect
    assert flash[:error].present?
    assert_equal 550, @ai_agent.reload.llm_daily_spend_cap_cents
  end

  test "update_settings rejects a spend cap too large for the column" do
    # A value past int4 parses fine and passes validation, then raises
    # ActiveModel::RangeError at save — it must get the friendly-error path,
    # not a 500.
    @ai_agent.update!(llm_daily_spend_cap_cents: 550)
    sign_in_as(@user, tenant: @tenant)

    post "/ai-agents/#{@ai_agent_handle}/settings", params: { llm_daily_spend_cap: "30000000" }

    assert_response :redirect
    assert flash[:error].present?
    assert_equal 550, @ai_agent.reload.llm_daily_spend_cap_cents
  end

  # === Agent notification preferences ===

  test "agent settings page renders a single on/off toggle per notification type, no email column" do
    sign_in_as(@user, tenant: @tenant)

    get "/ai-agents/#{@ai_agent_handle}/settings"

    assert_response :success
    assert_includes response.body, "Notification preferences"
    # Simple boolean toggle: the in_app box is present...
    assert_includes response.body, "notifications[comment][in_app]"
    # ...and the email column is gone (agents have no email address).
    assert_not_includes response.body, "notifications[comment][email]"
    # Folded into the single page form — no separate notifications submit.
    assert_not_includes response.body, "Save notification preferences"
    assert_includes response.body, "Save Settings"
  end

  test "update_settings saves agent notification toggles from the single page form" do
    sign_in_as(@user, tenant: @tenant)

    # Main form submit: notifications_present marks the matrix; comment is
    # checked (in_app), mention is unchecked (box omitted by the browser).
    post "/ai-agents/#{@ai_agent_handle}/settings",
      params: { name: "Test AI Agent", notifications_present: "1",
                notifications: { comment: { in_app: "true" } } }

    assert_response :redirect
    tu = @ai_agent.tenant_users.find_by(tenant: @tenant)
    assert tu.notification_enabled?("comment", "in_app"), "checked toggle stays on"
    refute tu.notification_enabled?("mention", "in_app"), "unchecked toggle recorded as off"
    refute tu.notification_enabled?("comment", "email"), "agents never get email — recorded off"
  end

  test "update_settings stores unchecked channels as false, not nil" do
    sign_in_as(@user, tenant: @tenant)

    post "/ai-agents/#{@ai_agent_handle}/settings",
      params: { name: "Test AI Agent", notifications_present: "1",
                notifications: { comment: { in_app: "true" } } }

    assert_response :redirect
    tu = @ai_agent.tenant_users.find_by(tenant: @tenant)
    # The agent form never renders an email box, so the email channel is always
    # absent from the payload. complete: true must record those as the boolean
    # false — not JSON null (the column is typed Hash[String, Boolean]). Assert
    # with == false (not !value) so a nil regression fails here.
    assert_equal false, tu.notification_preferences.dig("comment", "email")
    assert_equal false, tu.notification_preferences.dig("mention", "in_app"),
      "unchecked in_app box stored as false, not nil"
  end

  test "update_settings rolls back notification preferences when the agent save fails" do
    sign_in_as(@user, tenant: @tenant)
    tu = @ai_agent.tenant_users.find_by(tenant: @tenant)
    assert tu.notification_enabled?("comment", "in_app"), "default on"

    # mode is immutable after creation, so submitting a different mode fails
    # @ai_agent.save. The notification toggles (comment unchecked) must NOT be
    # committed — no partial write.
    post "/ai-agents/#{@ai_agent_handle}/settings",
      params: { name: "Test AI Agent", mode: "external", notifications_present: "1",
                notifications: { mention: { in_app: "true" } } }

    assert_response :redirect
    tu.reload
    assert tu.notification_enabled?("comment", "in_app"),
      "prefs unchanged because the agent save failed"
  end

  test "update_settings leaves notification preferences untouched when the marker is absent" do
    sign_in_as(@user, tenant: @tenant)
    tu = @ai_agent.tenant_users.find_by(tenant: @tenant)
    assert tu.notification_enabled?("comment", "in_app"), "default on"

    # A submit that does not carry the notification fields (no marker) must not
    # wipe the matrix to all-off.
    post "/ai-agents/#{@ai_agent_handle}/settings", params: { name: "Renamed" }

    assert_response :redirect
    tu.reload
    assert tu.notification_enabled?("comment", "in_app"), "preferences preserved"
  end

  test "parent can update an agent's notification preferences via the markdown action" do
    sign_in_as(@user, tenant: @tenant)

    post "/ai-agents/#{@ai_agent_handle}/settings/actions/update_notification_preferences",
      params: { notifications: { mention: { email: "false" } } },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    tu = @ai_agent.tenant_users.find_by(tenant: @tenant)
    refute tu.notification_enabled?("mention", "email"), "supplied toggle applied"
    assert tu.notification_enabled?("comment", "in_app"), "untouched type keeps its default"
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
    sign_in_with_ai_agents_reverify(@user)

    assert_no_difference "User.where(user_type: 'ai_agent').count" do
      post "/ai-agents/new/actions/create_ai_agent", params: { name: "No Confirm Agent", mode: "internal" }
    end

    assert_response :redirect
    assert_match %r{/ai-agents/new}, response.location
  end

  test "create does NOT require billing confirmation for app_admin (billing-exempt)" do
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    sign_in_with_ai_agents_reverify(@user)

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
    sign_in_with_ai_agents_reverify(@user)

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

  # Agents that hold user-issued tokens must be external-mode — internal
  # agents cannot have API keys.
  def create_external_agent_with_handle(name:)
    agent = create_ai_agent(parent: @user, name: name, agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    [agent, agent.tenant_users.find_by(tenant: @tenant).handle]
  end

  test "settings page shows client_name as the token label for Connect-flow tokens" do
    agent, handle = create_external_agent_with_handle(name: "Connect Label Agent")
    ApiToken.create!(
      tenant: @tenant,
      user: agent,
      name: "Cursor connection",
      client_name: "Cursor",
      scopes: ["read:all"]
    )
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{handle}/settings"
    assert_response :success
    assert_includes response.body, "Client"
    assert_includes response.body, "Cursor"
  end

  test "settings page falls back to token name when client_name is blank" do
    agent, handle = create_external_agent_with_handle(name: "Fallback Label Agent")
    ApiToken.create!(
      tenant: @tenant,
      user: agent,
      name: "Hand-rolled paste token",
      scopes: ["read:all"]
    )
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{handle}/settings"
    assert_response :success
    assert_includes response.body, "Hand-rolled paste token"
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
    sign_in_with_ai_agents_reverify(@user)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Blocked Internal Agent",
      mode: "internal",
      confirm_billing: "1",
    }
    assert_response :forbidden
  end

  test "create with mode=external is blocked when external_ai_agents is disabled" do
    @tenant.disable_feature_flag!("external_ai_agents")
    sign_in_with_ai_agents_reverify(@user)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Blocked External Agent",
      mode: "external",
      confirm_billing: "1",
    }
    assert_response :forbidden
  end

  test "create with missing mode defaults to external and is blocked when external_ai_agents is disabled" do
    @tenant.disable_feature_flag!("external_ai_agents")
    sign_in_with_ai_agents_reverify(@user)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Blocked Default-mode Agent",
      confirm_billing: "1",
    }
    assert_response :forbidden
  end

  test "agent itself can read its own /ai-agents/handle/settings via authorize_parent_or_self" do
    @tenant.enable_api!
    agent, handle = create_external_agent_with_handle(name: "Self-Read Agent")
    token = ApiToken.create!(
      user: agent,
      tenant: @tenant,
      name: "Self-Read Token",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      token_type: "rest"
    )
    get "/ai-agents/#{handle}/settings",
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
    agent, handle = create_external_agent_with_handle(name: "Self-Write Agent")
    token = ApiToken.create!(
      user: agent,
      tenant: @tenant,
      name: "Self-Write Token",
      scopes: ApiToken.write_scopes + ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      token_type: "rest"
    )
    post "/ai-agents/#{handle}/settings",
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
    assert_not_includes response.body, "Run Task"
    assert_includes response.body, "Settings"
    # External agents manage their notification webhook on settings — no
    # automations surface, no Automations button in the agent list.
    assert_not_includes response.body, "Automations"
  end

  test "external-only: show page is reachable and hides Run Task button" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @ai_agent.update_columns(agent_configuration: { "mode" => "external" })
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}"
    assert_response :success
    assert_not_includes response.body, ">Run Task"
  end

  test "external-only: new agent form is reachable" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_with_ai_agents_reverify(@user)
    get "/ai-agents/new"
    assert_response :success
  end

  test "external-only: new agent form hides Mode radio and sends hidden mode=external" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_with_ai_agents_reverify(@user)
    get "/ai-agents/new"
    assert_response :success
    assert_no_match(/radio_button.*mode/, response.body)
    assert_no_match(/<label[^>]*>\s*<input[^>]*type="radio"[^>]*name="mode"/, response.body)
    assert_match(/<input[^>]*type="hidden"[^>]*name="mode"[^>]*value="external"/, response.body)
  end

  test "create with a name whose default handle is taken auto-disambiguates, no error" do
    # Name and handle are independent. A generic name like "Claude" whose
    # derived handle is already taken must not error — leaving the handle
    # field blank auto-generates a distinct one, like human signup does.
    sign_in_with_ai_agents_reverify(@user)
    existing = create_ai_agent(parent: @user, name: "Collision Target")
    existing_handle = @tenant.add_user!(existing).handle
    before_ids = User.where(user_type: "ai_agent").pluck(:id)

    assert_difference -> { User.where(user_type: "ai_agent").count }, 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: {
        name: "Collision Target", # same name → same base handle, left blank
        mode: "external",
        confirm_billing: "1",
      }
    end

    assert_response :redirect
    new_agent = User.where(user_type: "ai_agent").where.not(id: before_ids).first
    new_handle = new_agent.tenant_users.find_by(tenant: @tenant).handle
    assert_not_equal existing_handle, new_handle, "expected a distinct auto-disambiguated handle"
    assert_match(/\A#{Regexp.escape(existing_handle)}-/, new_handle, "expected the taken base with a suffix")
  end

  test "create with an explicitly-typed handle that is taken surfaces a friendly error, not a 500" do
    sign_in_with_ai_agents_reverify(@user)
    existing = create_ai_agent(parent: @user, name: "Existing Agent")
    existing_handle = @tenant.add_user!(existing).handle

    assert_no_difference -> { User.where(user_type: "ai_agent").count } do
      post "/ai-agents/new/actions/create_ai_agent", params: {
        name: "A Totally Different Display Name",
        handle: existing_handle,
        mode: "external",
        confirm_billing: "1",
      }
    end

    assert_response :redirect, "should redirect back to the form, not 500"
    assert_match(/handle|already|taken|in use|different/i, flash[:alert] || flash[:error] || flash[:notice] || "",
                 "flash must explain why creation failed so the user can pick a different handle")
    follow_redirect!
    assert_match(/handle|already|taken|in use|different/i, response.body,
                 "flash should be visible in the rendered form so the user knows why it failed")
  end

  test "create with an explicit handle uses that handle, independent of the name" do
    sign_in_with_ai_agents_reverify(@user)
    chosen = "helper-#{SecureRandom.hex(3)}"
    before_ids = User.where(user_type: "ai_agent").pluck(:id)

    assert_difference -> { User.where(user_type: "ai_agent").count }, 1 do
      post "/ai-agents/new/actions/create_ai_agent", params: {
        name: "My Helper Bot",
        handle: chosen,
        mode: "external",
        confirm_billing: "1",
      }
    end

    new_agent = User.where(user_type: "ai_agent").where.not(id: before_ids).first
    assert_equal chosen, new_agent.tenant_users.find_by(tenant: @tenant).handle
    assert_equal "My Helper Bot", new_agent.name, "the display name is preserved independent of the handle"
  end

  test "create via the markdown action with a taken handle returns an action error, not a 500" do
    sign_in_with_ai_agents_reverify(@user)
    existing = create_ai_agent(parent: @user, name: "Existing Md Agent")
    existing_handle = @tenant.add_user!(existing).handle

    assert_no_difference -> { User.where(user_type: "ai_agent").count } do
      post "/ai-agents/new/actions/create_ai_agent",
           params: { name: "New Md Agent", handle: existing_handle, mode: "external", confirm_billing: "1" },
           headers: { "Accept" => "text/markdown" }
    end

    assert_response :unprocessable_entity
    assert_match(/handle|taken|already|different/i, response.body)
  end

  test "update_settings with a taken handle surfaces a friendly error, not a 500" do
    sign_in_as(@user, tenant: @tenant)
    other = create_ai_agent(parent: @user, name: "Other Agent")
    taken_handle = @tenant.add_user!(other).handle
    original_handle = @ai_agent.tenant_users.find_by(tenant: @tenant).handle

    post "/ai-agents/#{original_handle}/settings", params: { new_handle: taken_handle }

    assert_response :redirect
    assert_match(/handle|taken|already|reserved/i, flash[:error].to_s)
    assert_equal original_handle, @ai_agent.tenant_users.find_by(tenant: @tenant).reload.handle,
                 "the handle must be unchanged after a rejected rename"
  end

  test "external-only: admin user creating an agent does NOT get pending_billing_setup even with inactive stripe_customer" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    # Pre-existing inactive stripe_customer (e.g. subscription was canceled or never activated)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_admin_test", active: false)

    sign_in_with_ai_agents_reverify(@user)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Admin External Agent",
      mode: "external",
      generate_token: "1",
      confirm_billing: "1",
    }

    new_agent = @user.ai_agents.find_by(name: "Admin External Agent")
    assert new_agent
    assert_not new_agent.pending_billing_setup?,
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

    sign_in_with_ai_agents_reverify(@user)
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
    sign_in_with_ai_agents_reverify(@user)
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

  test "external-only: generate_token defaults the new token to the mcp type" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_with_ai_agents_reverify(@user)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "MCP-only Default Agent",
      mode: "external",
      generate_token: "1",
      confirm_billing: "1",
    }

    new_agent = @user.ai_agents.find_by(name: "MCP-only Default Agent")
    assert new_agent
    token = ApiToken.unscoped.where(user_id: new_agent.id).first
    assert token, "token should be persisted"
    assert token.mcp_type?, "auto-generated agent token must default to the mcp type"
  end

  test "external-only: generate_token with the legacy mcp_only=0 alias honors the override" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_with_ai_agents_reverify(@user)
    post "/ai-agents/new/actions/create_ai_agent", params: {
      name: "Direct-REST Agent",
      mode: "external",
      generate_token: "1",
      mcp_only: "0",
      confirm_billing: "1",
    }

    new_agent = @user.ai_agents.find_by(name: "Direct-REST Agent")
    assert new_agent
    token = ApiToken.unscoped.where(user_id: new_agent.id).first
    assert token
    assert token.rest_type?, "principal explicitly opted into a rest token via the legacy alias"
  end

  test "external-only: external agent creation without generate_token redirects (no token rendered)" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    sign_in_with_ai_agents_reverify(@user)
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
    sign_in_with_ai_agents_reverify(@user)
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
    sign_in_with_ai_agents_reverify(@user)
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

  # === MCP Tool Call Log Tests ===

  def create_mcp_log_for(agent, **attrs)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    log = McpToolCallLog.create!({
      tenant: @tenant,
      user: agent,
      tool_name: "fetch_page",
      arguments: { "path" => "/whoami" },
      status: "ok",
      duration_ms: 12,
    }.merge(attrs))
    Tenant.clear_thread_scope
    log
  end

  test "human user can access the MCP tool calls list for their agent" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls"
    assert_response :success
  end

  test "MCP tool calls list shows the agent's logged calls" do
    create_mcp_log_for(@ai_agent, tool_name: "fetch_page")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls"
    assert_response :success
    assert_match "fetch_page", response.body
  end

  test "MCP tool calls list surfaces path, action, and intention" do
    create_mcp_log_for(@ai_agent,
                       tool_name: "execute_action",
                       arguments: { "path" => "/collectives/team/n/abc123", "action" => "add_comment" },
                       context: { "intention" => "Reply to Dan on the doc thread", "visibility" => "shared" })
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls"
    assert_response :success
    assert_match "/collectives/team/n/abc123", response.body
    assert_match "add_comment", response.body
    assert_match "Reply to Dan on the doc thread", response.body
  end

  test "MCP tool calls list renders markdown" do
    create_mcp_log_for(@ai_agent)
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.content_type, "text/markdown"
    assert_match "MCP Tool Calls", response.body
  end

  test "unauthenticated user is redirected from MCP tool calls list" do
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "MCP tool calls list returns 404 for non-existent agent" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/non-existent-handle/mcp-tool-calls"
    assert_response :not_found
  end

  test "user cannot view another user's agent MCP tool calls" do
    other_user = create_user
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls"
    assert_response :not_found
  end

  test "MCP tool calls list is forbidden when AI agents feature is disabled" do
    @tenant.set_feature_flag!("internal_ai_agents", false)
    @tenant.set_feature_flag!("external_ai_agents", false)
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls"
    assert_response :forbidden
  end

  test "human user can view a single MCP tool call detail" do
    log = create_mcp_log_for(@ai_agent, tool_name: "execute_action",
                                        arguments: { "path" => "/x", "action" => "add_comment" },
                                        request_id: "req-xyz")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls/#{log.id}"
    assert_response :success
    assert_match "execute_action", response.body
  end

  def attach_resource_to_log(log, display_path:)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = create_note(tenant: @tenant, collective: @collective, created_by: @ai_agent)
    McpToolCallResource.create!(
      tenant: @tenant,
      mcp_tool_call_log: log,
      resource: note,
      resource_collective: @collective,
      action_name: "create_note",
      display_path: display_path,
    )
  ensure
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "MCP tool call detail renders a safe stored display_path as a link" do
    log = create_mcp_log_for(@ai_agent, tool_name: "execute_action", arguments: {})
    safe_path = "/collectives/#{@collective.handle}/n/abc123"
    attach_resource_to_log(log, display_path: safe_path)
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls/#{log.id}"
    assert_response :success
    assert_match %r{<a[^>]+href="#{Regexp.escape(safe_path)}"}, response.body
  end

  # Regression guard for the show_mcp_tool_call.html.erb review finding
  # (Harmonic PR #308): a stored `display_path` is only ever rendered as an
  # `href` when it's a same-origin relative path. Server-side path computation
  # can't produce a scheme, but if one ever reached the column it must render
  # as inert text, never as an executable javascript: link.
  test "MCP tool call detail renders a hostile stored display_path as inert text, not an href" do
    log = create_mcp_log_for(@ai_agent, tool_name: "execute_action", arguments: {})
    attach_resource_to_log(log, display_path: "javascript:alert(document.cookie)")
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls/#{log.id}"
    assert_response :success
    # The value is still shown to the human operator ...
    assert_match "javascript:alert(document.cookie)", response.body
    # ... but never as a clickable link that would execute it.
    assert_no_match %r{href=["']\s*javascript:}i, response.body
  end

  test "MCP tool call detail returns 404 for an unknown log id" do
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls/00000000-0000-0000-0000-000000000000"
    assert_response :not_found
  end

  test "MCP tool call detail returns 404 for a log belonging to a different agent" do
    other_agent = create_ai_agent(parent: @user, name: "Other Agent")
    @tenant.add_user!(other_agent)
    log = create_mcp_log_for(other_agent, tool_name: "search", arguments: {})
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{@ai_agent_handle}/mcp-tool-calls/#{log.id}"
    assert_response :not_found
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
