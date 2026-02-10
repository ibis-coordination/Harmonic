require "test_helper"

class ActionAuthorizationTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )
  end

  # Test: All actions must have authorization defined
  test "all actions have authorization defined" do
    ActionsHelper::ACTION_DEFINITIONS.each do |name, definition|
      assert definition.key?(:authorization),
        "Action '#{name}' must have :authorization defined"
    end
  end

  # Test: Unknown actions are denied
  test "unknown actions are denied" do
    refute ActionAuthorization.authorized?("nonexistent_action", @user, {})
  end

  # Test: Public authorization allows unauthenticated users
  test "public authorization allows nil user" do
    # Temporarily add a public action for testing
    original = ActionsHelper::ACTION_DEFINITIONS.dup

    # We can't modify the frozen hash, so test the check_authorization method directly
    assert ActionAuthorization.check_authorization(:public, nil, {})
  end

  # Test: Authenticated authorization requires a user
  test "authenticated authorization requires a user" do
    assert ActionAuthorization.check_authorization(:authenticated, @user, {})
    refute ActionAuthorization.check_authorization(:authenticated, nil, {})
  end

  # Test: System admin authorization
  test "system_admin authorization checks sys_admin flag" do
    refute ActionAuthorization.check_authorization(:system_admin, @user, {})

    @user.update!(sys_admin: true)
    assert ActionAuthorization.check_authorization(:system_admin, @user, {})
  end

  # Test: App admin authorization
  test "app_admin authorization checks app_admin flag" do
    refute ActionAuthorization.check_authorization(:app_admin, @user, {})

    @user.update!(app_admin: true)
    assert ActionAuthorization.check_authorization(:app_admin, @user, {})
  end

  # Test: Tenant admin authorization
  test "tenant_admin authorization checks tenant_user admin role" do
    refute ActionAuthorization.check_authorization(:tenant_admin, @user, {})

    @user.tenant_user.add_role!("admin")
    assert ActionAuthorization.check_authorization(:tenant_admin, @user, {})
  end

  # Test: Superagent admin authorization
  test "superagent_admin authorization checks superagent_member admin role" do
    context = { studio: @superagent }
    refute ActionAuthorization.check_authorization(:superagent_admin, @user, context)

    sm = @user.superagent_members.find_by(superagent_id: @superagent.id)
    sm.add_role!("admin")
    assert ActionAuthorization.check_authorization(:superagent_admin, @user, context)
  end

  # Test: Studio member authorization
  test "superagent_member authorization checks studio membership" do
    context = { studio: @superagent }

    # User is already a member (from setup)
    assert ActionAuthorization.check_authorization(:superagent_member, @user, context)

    # Create a user who is not a member
    non_member = create_user
    @tenant.add_user!(non_member)
    refute ActionAuthorization.check_authorization(:superagent_member, non_member, context)
  end

  # Test: Resource owner authorization
  test "resource_owner authorization checks created_by_id" do
    note = Note.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      text: "Test note"
    )
    context = { resource: note }

    assert ActionAuthorization.check_authorization(:resource_owner, @user, context)

    other_user = create_user
    @tenant.add_user!(other_user)
    refute ActionAuthorization.check_authorization(:resource_owner, other_user, context)
  end

  # Test: Self authorization
  test "self authorization checks target_user matches user" do
    context = { target_user: @user }
    assert ActionAuthorization.check_authorization(:self, @user, context)

    other_user = create_user
    @tenant.add_user!(other_user)
    refute ActionAuthorization.check_authorization(:self, other_user, context)
  end

  # Test: Representative authorization
  test "representative authorization checks can_represent?" do
    # Create a ai_agent owned by @user
    ai_agent = User.create!(
      email: "ai_agent@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent)
    context = { target: ai_agent }

    # Parent can represent their ai_agent
    assert ActionAuthorization.check_authorization(:representative, @user, context)

    # Other users cannot
    other_user = create_user
    @tenant.add_user!(other_user)
    refute ActionAuthorization.check_authorization(:representative, other_user, context)
  end

  # Test: Array authorization (OR logic)
  test "array authorization allows if any check passes" do
    # Provide both target_user (for :self) and target (for :representative)
    context = { target_user: @user, target: @user }

    # Test with [:self, :representative]
    assert ActionAuthorization.check_authorization([:self, :representative], @user, context)

    # Create another user who is neither self nor representative
    other_user = create_user
    @tenant.add_user!(other_user)
    refute ActionAuthorization.check_authorization([:self, :representative], other_user, context)
  end

  # Test: Proc authorization
  test "proc authorization executes custom logic" do
    custom_auth = ->(user, context) { user.email.include?("global") }

    assert ActionAuthorization.check_authorization(custom_auth, @user, {})

    other_user = create_user(email: "other@example.com")
    @tenant.add_user!(other_user)
    refute ActionAuthorization.check_authorization(custom_auth, other_user, {})
  end

  # Test: Admin actions are not visible to regular users
  test "admin actions are not visible to regular authenticated users" do
    # retry_sidekiq_job requires system_admin
    refute ActionAuthorization.authorized?("retry_sidekiq_job", @user, {})

    # create_tenant requires app_admin
    refute ActionAuthorization.authorized?("create_tenant", @user, {})

    # suspend_user requires app_admin
    refute ActionAuthorization.authorized?("suspend_user", @user, {})

    # update_tenant_settings requires tenant_admin
    refute ActionAuthorization.authorized?("update_tenant_settings", @user, {})
  end

  # Test: Authenticated actions are visible to logged-in users
  test "authenticated actions are visible to logged-in users" do
    assert ActionAuthorization.authorized?("search", @user, {})
    assert ActionAuthorization.authorized?("create_studio", @user, {})
    assert ActionAuthorization.authorized?("dismiss", @user, {})
  end

  # Test: Studio member actions are permissive for listing, strict for execution
  test "studio member actions are permissive without context, strict with context" do
    # Without context (for listing), should be permissive for authenticated users
    assert ActionAuthorization.authorized?("send_heartbeat", @user, {})

    # Without context, unauthenticated should still fail
    refute ActionAuthorization.authorized?("send_heartbeat", nil, {})

    # With context where user is member, should pass
    context = { studio: @superagent }
    assert ActionAuthorization.authorized?("send_heartbeat", @user, context)

    # With context where user is NOT a member, should fail
    non_member = create_user
    @tenant.add_user!(non_member)
    refute ActionAuthorization.authorized?("send_heartbeat", non_member, context)
  end

  # Test: routes_and_actions_for_user filters out unauthorized actions
  test "routes_and_actions_for_user filters admin actions for regular users" do
    routes = ActionsHelper.routes_and_actions_for_user(@user)

    # Admin routes should be filtered out
    admin_routes = routes.select { |r| r[:route].start_with?("/admin") }
    admin_routes.each do |route_info|
      route_info[:actions].each do |action|
        action_name = action[:name]
        # Regular user should not see system_admin, app_admin, or tenant_admin actions
        refute_includes ["retry_sidekiq_job", "create_tenant", "suspend_user", "unsuspend_user", "update_tenant_settings"], action_name,
          "Regular user should not see admin action '#{action_name}'"
      end
    end
  end

  # Test: Admin user sees admin actions
  test "app_admin user sees app_admin actions" do
    @user.update!(app_admin: true)
    routes = ActionsHelper.routes_and_actions_for_user(@user)

    # Find the admin users route
    admin_users_route = routes.find { |r| r[:route] == "/admin/users/:handle" }
    assert admin_users_route, "Admin users route should be visible to app_admin"

    action_names = admin_users_route[:actions].map { |a| a[:name] }
    assert_includes action_names, "suspend_user"
    assert_includes action_names, "unsuspend_user"
  end

  # Test: System admin sees system admin actions
  test "system_admin user sees system_admin actions" do
    @user.update!(sys_admin: true)
    routes = ActionsHelper.routes_and_actions_for_user(@user)

    # Find the sidekiq jobs route
    sidekiq_route = routes.find { |r| r[:route] == "/admin/sidekiq/jobs/:jid" }
    assert sidekiq_route, "Sidekiq jobs route should be visible to system_admin"

    action_names = sidekiq_route[:actions].map { |a| a[:name] }
    assert_includes action_names, "retry_sidekiq_job"
  end

  # Test: Tenant admin sees tenant admin actions
  test "tenant_admin user sees tenant_admin actions" do
    @user.tenant_user.add_role!("admin")
    routes = ActionsHelper.routes_and_actions_for_user(@user)

    # Find the admin settings route
    admin_settings_route = routes.find { |r| r[:route] == "/admin/settings" }
    assert admin_settings_route, "Admin settings route should be visible to tenant_admin"

    action_names = admin_settings_route[:actions].map { |a| a[:name] }
    assert_includes action_names, "update_tenant_settings"
  end

  # Test: Webhook authorization is context-aware
  test "webhook authorization allows authenticated users with no context" do
    # With no specific context, authenticated users can see webhook actions
    assert ActionAuthorization.authorized?("create_webhook", @user, {})
    assert ActionAuthorization.authorized?("update_webhook", @user, {})
    assert ActionAuthorization.authorized?("delete_webhook", @user, {})
    assert ActionAuthorization.authorized?("test_webhook", @user, {})

    # Unauthenticated users cannot
    refute ActionAuthorization.authorized?("create_webhook", nil, {})
  end

  test "webhook authorization requires superagent_admin for studio webhooks" do
    context = { studio: @superagent }

    # Regular member cannot manage studio webhooks
    refute ActionAuthorization.authorized?("create_webhook", @user, context)
    refute ActionAuthorization.authorized?("update_webhook", @user, context)
    refute ActionAuthorization.authorized?("delete_webhook", @user, context)

    # Studio admin can manage studio webhooks
    sm = @user.superagent_members.find_by(superagent_id: @superagent.id)
    sm.add_role!("admin")
    assert ActionAuthorization.authorized?("create_webhook", @user, context)
    assert ActionAuthorization.authorized?("update_webhook", @user, context)
    assert ActionAuthorization.authorized?("delete_webhook", @user, context)
  end

  test "webhook authorization allows self for user webhooks" do
    context = { target_user: @user }

    # User can manage their own webhooks
    assert ActionAuthorization.authorized?("create_webhook", @user, context)
    assert ActionAuthorization.authorized?("update_webhook", @user, context)
    assert ActionAuthorization.authorized?("delete_webhook", @user, context)

    # Other users cannot manage this user's webhooks
    other_user = create_user
    @tenant.add_user!(other_user)
    refute ActionAuthorization.authorized?("create_webhook", other_user, context)
  end

  test "webhook authorization allows representative for user webhooks" do
    # Create a ai_agent owned by @user
    ai_agent = User.create!(
      email: "webhook-ai_agent@example.com",
      name: "Webhook Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent)
    context = { target_user: ai_agent }

    # Parent (representative) can manage ai_agent's webhooks
    assert ActionAuthorization.authorized?("create_webhook", @user, context)

    # Unrelated user cannot
    other_user = create_user
    @tenant.add_user!(other_user)
    refute ActionAuthorization.authorized?("create_webhook", other_user, context)
  end

  # Test: Person-only actions (create_ai_agent, create_api_token)
  test "person-only actions are restricted to person user type" do
    # Person user can see these actions (no context = listing)
    assert ActionAuthorization.authorized?("create_ai_agent", @user, {})
    assert ActionAuthorization.authorized?("create_api_token", @user, {})

    # Create a ai_agent - ai_agents cannot create other ai_agents or API tokens
    ai_agent = User.create!(
      email: "ai_agent-test@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent)

    refute ActionAuthorization.authorized?("create_ai_agent", ai_agent, {})
    refute ActionAuthorization.authorized?("create_api_token", ai_agent, {})

    # Create a superagent_proxy - proxy users also cannot create ai_agents or API tokens
    proxy = User.create!(
      email: "proxy-test@example.com",
      name: "Test Proxy",
      user_type: "superagent_proxy"
    )
    @tenant.add_user!(proxy)

    refute ActionAuthorization.authorized?("create_ai_agent", proxy, {})
    refute ActionAuthorization.authorized?("create_api_token", proxy, {})
  end

  test "person-only actions with context check self or representative" do
    context = { target_user: @user, target: @user }

    # Person user acting on themselves
    assert ActionAuthorization.authorized?("create_ai_agent", @user, context)
    assert ActionAuthorization.authorized?("create_api_token", @user, context)

    # Create a ai_agent owned by @user
    ai_agent = User.create!(
      email: "ai_agent-context@example.com",
      name: "Context Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent)
    ai_agent_context = { target_user: ai_agent, target: ai_agent }

    # Parent (person) can create tokens/ai_agents for their ai_agent
    assert ActionAuthorization.authorized?("create_ai_agent", @user, ai_agent_context)
    assert ActionAuthorization.authorized?("create_api_token", @user, ai_agent_context)

    # Other person cannot
    other_user = create_user
    @tenant.add_user!(other_user)
    refute ActionAuthorization.authorized?("create_ai_agent", other_user, ai_agent_context)
    refute ActionAuthorization.authorized?("create_api_token", other_user, ai_agent_context)
  end
end
