# frozen_string_literal: true

require "test_helper"

# Proves the security boundary around User#system_role.
#
# system_role: "trio" grants privileges that non-system users do not have:
# - billing exemption in AgentRunnerDispatchService and AutomationExecutor
# - permission to be added as a member of a private workspace
# - permission to claim the reserved TenantUser handle "trio"
#
# So unauthorized assignment of `system_role` would be a privilege
# escalation. These tests document and verify that no user-controllable
# path can set or change `system_role`.
class SystemRoleProtectionTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Honor-system login ===

  test "honor-system login ignores system_role param when creating a user" do
    if ENV["AUTH_MODE"] != "honor_system"
      skip "honor-system login route not mounted in this AUTH_MODE"
    end

    fresh_email = "freshie-#{SecureRandom.hex(4)}@example.com"
    post "/login", params: { email: fresh_email, name: "Freshie", system_role: "trio" }

    new_user = User.find_by(email: fresh_email)
    assert new_user, "expected the login flow to have created a user"
    assert_nil new_user.system_role, "expected system_role to be nil; was #{new_user.system_role.inspect}"
    assert_not new_user.system?, "expected the user not to be a system agent"
  end

  # === AI agent creation (web) ===

  test "POST execute_create_ai_agent ignores system_role param" do
    @tenant.set_feature_flag!("ai_agents", true)
    sign_in_as(@user, tenant: @tenant)

    assert_difference -> { User.where(user_type: "ai_agent").count }, 1 do
      post "/ai-agents/new/actions/create_ai_agent",
        params: { name: "Sneaky Agent", mode: "external", system_role: "trio" }
    end

    created = User.where(user_type: "ai_agent").order(created_at: :desc).first
    assert_nil created.system_role, "expected system_role to be nil; was #{created.system_role.inspect}"
    assert_equal @user.id, created.parent_id, "agent should belong to the creating user, not a system slot"
  end

  # === User profile update ===

  test "POST update_profile cannot set system_role on the settings user" do
    sign_in_as(@user, tenant: @tenant)
    refute @user.system?, "precondition: starts as non-system"

    post "/u/#{@user.handle}/settings/profile",
      params: { name: "Renamed", system_role: "trio" }

    @user.reload
    assert_nil @user.system_role, "system_role should remain nil after update_profile"
    refute @user.system?, "user should not become a system agent via update_profile"
  end

  test "POST update_profile cannot rename a non-trio user's handle to 'trio'" do
    sign_in_as(@user, tenant: @tenant)
    original_handle = @user.tenant_user.handle

    # The TenantUser reserved-handle validation raises ActiveRecord::RecordInvalid
    # at the update! call site. Either Rails serves a 500 or the controller rescues;
    # what matters for security is that the handle is not persisted as "trio".
    begin
      post "/u/#{@user.handle}/settings/profile", params: { new_handle: "trio" }
    rescue ActiveRecord::RecordInvalid
      # Expected — validation rejected the change. Continue to verify state.
    end

    @user.tenant_user.reload
    assert_equal original_handle, @user.tenant_user.handle,
      "expected the handle to remain unchanged because 'trio' is reserved"
  end

  # === AI agent settings update ===

  test "POST ai_agent update_settings cannot rename an agent's handle to 'trio'" do
    @tenant.set_feature_flag!("ai_agents", true)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    ai_agent = create_ai_agent(parent: @user, name: "Regular Agent")
    @tenant.add_user!(ai_agent)
    agent_handle = ai_agent.tenant_users.find_by(tenant: @tenant).handle

    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(@user, tenant: @tenant)
    begin
      post "/ai-agents/#{agent_handle}/settings", params: { new_handle: "trio" }
    rescue ActiveRecord::RecordInvalid
      # Expected — validation rejected the change. Continue to verify state.
    end

    ai_agent.tenant_users.find_by(tenant: @tenant).reload
    assert_equal agent_handle, ai_agent.tenant_users.find_by(tenant: @tenant).handle,
      "non-trio agent should not be able to claim handle 'trio'"
  end

  # === Direct model-level enforcement (defense in depth) ===

  test "TenantUser validation rejects handle 'trio' even when set via update!" do
    tenant = create_tenant(subdomain: "sr-protect-#{SecureRandom.hex(4)}")
    user = create_user(email: "regular-#{SecureRandom.hex(4)}@example.com")
    tu = tenant.add_user!(user)
    assert_not_equal "trio", tu.handle

    assert_raises(ActiveRecord::RecordInvalid) do
      tu.update!(handle: "trio")
    end
  end

  # === Confirm the only legitimate creator works ===
  #
  # TrioSeeder is the ONLY code path that creates a user with
  # system_role: "trio". This test exists so that if anyone adds
  # another creator in the future, it surfaces here as the only place
  # creating system users — and the reviewer can re-evaluate.

  test "TrioSeeder is the only documented creator of system_role: 'trio' users" do
    # Match hash-literal assignments (`system_role: "trio",`) which is the
    # shape that appears inside User.create!(...) calls. Query usage —
    # `.where(users: { system_role: "trio" })` — ends with `}` instead of
    # a comma and is intentionally not flagged.
    sources = Dir.glob("app/**/*.rb").select do |file|
      content = File.read(file)
      content.match?(/system_role:\s*["']trio["']\s*,/)
    end

    # Migrations also reference "trio" but live under db/, not app/.
    # If this list grows, a new code path is creating system users —
    # re-evaluate the security model before merging.
    assert_equal ["app/services/trio_seeder.rb"], sources.sort,
      "Expected TrioSeeder to be the sole creator of system_role: 'trio' users; " \
      "found additional sources: #{sources.inspect}"
  end
end
