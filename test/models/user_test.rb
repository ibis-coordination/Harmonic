require "test_helper"

class UserTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "user-test-#{SecureRandom.hex(4)}")
    @user = create_user(email: "usertest_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @collective = create_collective(tenant: @tenant, created_by: @user, handle: "user-collective-#{SecureRandom.hex(4)}")
    @collective.add_user!(@user)
    enable_stripe_billing_flag!(@tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  # === Basic Creation Tests ===

  test "User.create works" do
    user = User.create!(
      email: "#{SecureRandom.hex(8)}@example.com",
      name: 'Test Person',
      user_type: "human"
    )
    assert user.persisted?
    assert_equal 'Test Person', user.name
    assert_equal "human", user.user_type
    assert user.email.present?
  end

  test "User requires email" do
    user = User.new(name: "No Email", user_type: "human")
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "User requires name" do
    user = User.new(email: "noemail@example.com", user_type: "human")
    assert_not user.valid?
    assert_includes user.errors[:name], "can't be blank"
  end

  test "User requires valid user_type" do
    user = User.new(email: "test@example.com", name: "Test", user_type: "invalid")
    assert_not user.valid?
    assert_includes user.errors[:user_type], "is not included in the list"
  end

  # === User Type Helper Methods ===

  test "person? returns true for person user type" do
    user = User.new(user_type: "human")
    assert user.human?
    assert_not user.ai_agent?
    assert_not user.collective_identity?
  end

  test "ai_agent? returns true for ai_agent user type" do
    parent = create_user
    user = User.new(user_type: "ai_agent", parent_id: parent.id)
    assert user.ai_agent?
    assert_not user.human?
    assert_not user.collective_identity?
  end

  test "collective_identity? returns true for collective_identity user type" do
    user = User.new(user_type: "collective_identity")
    assert user.collective_identity?
    assert_not user.human?
    assert_not user.ai_agent?
  end

  # === Association Tests ===

  test "user has many tenant_users" do
    assert @user.tenant_users.any?
    assert_includes @user.tenants, @tenant
  end

  test "user has many collective_members" do
    assert @user.collective_members.any?
    assert_includes @user.collectives, @collective
  end

  test "user can have multiple tenants" do
    tenant2 = create_tenant(subdomain: "user-test2-#{SecureRandom.hex(4)}")
    tenant2.add_user!(@user)

    # Verify user is in second tenant by querying unscoped
    tenant2_membership = TenantUser.unscoped.find_by(user_id: @user.id, tenant_id: tenant2.id)
    assert tenant2_membership.present?, "User should be added to tenant2"
  end

  test "user can have ai_agent users as children" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "AiAgent User",
      user_type: "ai_agent",
      parent_id: @user.id
    )

    assert_includes @user.ai_agents, ai_agent
    assert_equal @user.id, ai_agent.parent_id
  end

  # === Display Name and Handle Tests ===

  test "display_name delegates to tenant_user" do
    @user.tenant_user.update!(display_name: "Custom Display Name")
    assert_equal "Custom Display Name", @user.display_name
  end

  test "handle delegates to tenant_user" do
    # Handle is set when user is added to tenant
    assert @user.handle.present?
    assert_equal @user.tenant_user.handle, @user.handle
  end

  test "display_name_with_parent for person returns display_name" do
    @user.tenant_user.update!(display_name: "Alice")
    assert_equal "Alice", @user.display_name_with_parent
  end

  test "display_name_with_parent for ai_agent includes parent name" do
    @user.tenant_user.update!(display_name: "Bob")
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "Alice Bot",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent)
    ai_agent.tenant_user.update!(display_name: "Alice")
    assert_equal "Alice (AI agent of Bob)", ai_agent.display_name_with_parent
  end

  test "parent returns parent user for ai_agent" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    assert_equal @user, ai_agent.parent
  end

  test "parent returns nil for person user" do
    assert_nil @user.parent
  end

  # === API JSON Tests ===

  test "api_json returns expected fields" do
    json = @user.api_json

    assert_equal @user.id, json[:id]
    assert_equal @user.user_type, json[:user_type]
    assert_equal @user.email, json[:email]
    assert_equal @user.display_name, json[:display_name]
    assert_equal @user.handle, json[:handle]
    assert_not_nil json[:created_at]
    assert_not_nil json[:updated_at]
  end

  # === Can Edit Tests ===

  test "user can edit themselves" do
    assert @user.can_edit?(@user)
  end

  test "user cannot edit other users" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    assert_not @user.can_edit?(other_user)
  end

  test "parent can edit ai_agent child" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "AiAgent User",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    assert @user.can_edit?(ai_agent)
  end

  # === Invite Acceptance Tests ===

  test "user can accept invite for themselves" do
    new_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Invite Collective",
      handle: "invite-collective-#{SecureRandom.hex(4)}"
    )
    invite = Invite.create!(
      tenant: @tenant,
      collective: new_collective,
      created_by: @user,
      invited_user: @user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    assert_not new_collective.user_is_member?(@user)
    @user.accept_invite!(invite)
    assert new_collective.user_is_member?(@user)
  end

  test "user cannot accept invite for another user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    # Add to tenant with unique handle
    TenantUser.create!(tenant: @tenant, user: other_user, handle: "other-user-#{SecureRandom.hex(4)}")

    invite = Invite.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      invited_user: other_user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    assert_raises RuntimeError, "Cannot accept invite for another user" do
      @user.accept_invite!(invite)
    end
  end

  # === Collectives Minus Main Tests ===

  test "collectives_minus_main excludes main collective" do
    # Set the thread tenant context so default scopes apply to @tenant.
    # Note: Tenant.scope_thread_to_tenant doesn't yield — it sets thread state
    # and returns the tenant. Previously this test wrapped the assertions in a
    # do/end block which was silently discarded, so the assertions never ran.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user)

    collectives = @user.collectives_minus_main
    assert_not_includes collectives, main_collective
    assert_includes collectives, @collective
  end

  # === External OAuth Tests ===

  test "external_oauth_identities excludes identity provider" do
    # Create an identity provider oauth identity
    OauthIdentity.create!(
      user: @user,
      provider: "identity",
      uid: @user.email
    )

    # Create a github oauth identity
    OauthIdentity.create!(
      user: @user,
      provider: "github",
      uid: "12345"
    )

    external = @user.external_oauth_identities
    assert_equal 1, external.count
    assert_equal "github", external.first.provider
  end

  # === Collective Identity User Tests ===

  test "collective_identity? returns true for collective's identity user" do
    identity_user = @collective.identity_user
    assert identity_user.collective_identity?
  end

  test "identity_collective returns associated collective" do
    identity_user = @collective.identity_user
    assert_equal @collective, identity_user.identity_collective
  end

  test "identity_collective returns nil for person user" do
    assert_nil @user.identity_collective
  end

  test "identity_collective returns nil for collective_identity without associated collective" do
    identity_user = User.create!(
      email: "#{SecureRandom.uuid}@not-a-real-email.com",
      name: "Orphan Identity",
      user_type: "collective_identity",
    )
    assert_nil identity_user.identity_collective
  end

  # === Representation Authorization Tests ===

  test "can_represent? returns true for identity user representing their own collective" do
    identity_user = @collective.identity_user
    assert identity_user.can_represent?(@collective)
  end

  test "can_represent? returns true for user with representative role" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    assert @user.can_represent?(@collective)
  end

  test "can_represent? returns false for user without representative role" do
    assert_not @user.can_represent?(@collective)
  end

  test "can_represent? returns true when any_member_can_represent is enabled" do
    @collective.settings['any_member_can_represent'] = true
    @collective.save!
    assert @user.can_represent?(@collective)
  end

  test "can_represent? returns false for non-member of collective" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User For Rep")
    @tenant.add_user!(other_user)
    assert_not other_user.can_represent?(@collective)
  end

  test "can_represent? returns true for parent representing ai_agent" do
    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent For Rep")
    @tenant.add_user!(ai_agent)
    assert @user.can_represent?(ai_agent)
  end

  test "can_represent? returns false for archived ai_agent" do
    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent Archived")
    @tenant.add_user!(ai_agent)
    ai_agent.tenant_user.archive!
    assert_not @user.can_represent?(ai_agent)
  end

  test "can_represent? returns false for non-parent user" do
    other_parent = create_user(email: "other_parent_#{SecureRandom.hex(4)}@example.com", name: "Other Parent")
    @tenant.add_user!(other_parent)
    ai_agent = create_ai_agent(parent: other_parent, name: "Other AiAgent")
    @tenant.add_user!(ai_agent)
    assert_not @user.can_represent?(ai_agent)
  end

  test "can_represent? returns true for representative representing collective identity" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    identity_user = @collective.identity_user
    assert @user.can_represent?(identity_user)
  end

  test "can_represent? returns false for non-representative trying to represent collective identity" do
    identity_user = @collective.identity_user
    assert_not @user.can_represent?(identity_user)
  end

  test "can_represent? returns true for collective identity when any_member_can_represent is enabled" do
    @collective.settings['any_member_can_represent'] = true
    @collective.save!
    identity_user = @collective.identity_user
    assert @user.can_represent?(identity_user)
  end

  test "can_represent? returns false for non-member trying to represent collective identity" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    identity_user = @collective.identity_user
    assert_not other_user.can_represent?(identity_user)
  end

  # === AiAgent Validation Tests ===

  test "ai_agent must have parent_id" do
    ai_agent = User.new(
      email: "ai_agent@example.com",
      name: "AiAgent Without Parent",
      user_type: "ai_agent",
      parent_id: nil,
    )
    assert_not ai_agent.valid?
    assert_includes ai_agent.errors[:parent_id], "must be set for AI agent users"
  end

  test "person cannot have parent_id" do
    person = User.new(
      email: "person@example.com",
      name: "Person With Parent",
      user_type: "human",
      parent_id: @user.id,
    )
    assert_not person.valid?
    assert_includes person.errors[:parent_id], "can only be set for AI agent users"
  end

  test "user cannot be their own parent" do
    # Need to save first since the validation checks persisted?
    test_user = create_user(email: "selfparent_#{SecureRandom.hex(4)}@example.com", name: "Self Parent Test")
    test_user.parent_id = test_user.id
    assert_not test_user.valid?
    assert_includes test_user.errors[:parent_id], "user cannot be its own parent"
  end

  # === System Agent Tests (system_role) ===

  test "system ai_agent can be created with nil parent_id" do
    agent = User.new(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio",
      user_type: "ai_agent",
      system_role: "trio",
      parent_id: nil,
    )
    assert agent.valid?, agent.errors.full_messages.to_sentence
  end

  test "system? returns true when system_role is set" do
    agent = User.new(user_type: "ai_agent", system_role: "trio", parent_id: nil)
    assert agent.system?
  end

  test "system? returns false when system_role is nil" do
    assert_not @user.system?
  end

  test "system_role rejects unknown values" do
    agent = User.new(
      email: "bad_#{SecureRandom.hex(4)}@example.com",
      name: "Bad",
      user_type: "ai_agent",
      system_role: "not_a_real_role",
      parent_id: nil,
    )
    assert_not agent.valid?
    assert_includes agent.errors[:system_role], "is not included in the list"
  end

  test "system_role allows nil for ordinary users and user-created agents" do
    assert @user.valid?
    assert_nil @user.system_role

    agent = User.create!(
      email: "agent_#{SecureRandom.hex(4)}@example.com",
      name: "User Agent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )
    assert agent.valid?
    assert_nil agent.system_role
  end

  test "trio system agent's handle is always 'trio' regardless of stored TenantUser handle" do
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio",
    )
    @tenant.add_user!(trio, handle: "trio-abc12345")

    assert_equal "trio", trio.handle, "expected trio's handle to be 'trio' even when TenantUser stores a hex-suffixed value"
  end

  test "trio system agent's path is always /u/trio regardless of stored TenantUser handle" do
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio",
    )
    @tenant.add_user!(trio, handle: "trio-abc12345")

    assert_equal "/u/trio", trio.path
  end

  test "creating a system ai_agent does not create a TrusteeGrant" do
    assert_difference -> { TrusteeGrant.count }, 0 do
      User.create!(
        email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
        name: "Trio",
        user_type: "ai_agent",
        system_role: "trio",
        parent_id: nil,
      )
    end
  end

  test "effective_identity_prompt returns the static Trio prompt for trio users, ignoring stale agent_configuration" do
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio",
      user_type: "ai_agent",
      system_role: "trio",
      parent_id: nil,
      agent_configuration: { "identity_prompt" => "stale cached prompt" },
    )

    assert_equal Trio::SystemPrompt.text, trio.effective_identity_prompt
  end

  test "effective_identity_prompt returns agent_configuration value for ordinary ai_agents" do
    agent = User.create!(
      email: "agent_#{SecureRandom.hex(4)}@example.com",
      name: "User Agent",
      user_type: "ai_agent",
      parent_id: @user.id,
      agent_configuration: { "identity_prompt" => "user-provided prompt" },
    )

    assert_equal "user-provided prompt", agent.effective_identity_prompt
  end

  test "effective_identity_prompt returns nil for ordinary agents without a configured prompt" do
    agent = User.create!(
      email: "agent_#{SecureRandom.hex(4)}@example.com",
      name: "User Agent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    assert_nil agent.effective_identity_prompt
  end

  # === Agent mode immutability ===

  test "agent_configuration mode cannot be changed after creation" do
    agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "internal" })

    agent.agent_configuration = (agent.agent_configuration || {}).merge("mode" => "external")
    assert_not agent.valid?
    assert_includes agent.errors[:agent_configuration], "mode cannot be changed after agent creation"
  end

  test "other agent_configuration fields can be changed after creation" do
    agent = create_ai_agent(
      parent: @user,
      agent_configuration: { "mode" => "internal", "identity_prompt" => "old" },
    )

    agent.agent_configuration = agent.agent_configuration.merge("identity_prompt" => "new")
    assert agent.valid?, "Expected to be able to update identity_prompt while keeping mode unchanged: #{agent.errors.full_messages}"
    agent.save!
    assert_equal "new", agent.reload.agent_configuration["identity_prompt"]
  end

  test "agent_configuration mode immutability does not block initial assignment on a fresh load" do
    # An existing agent with no mode set yet (legacy) should be allowed to set
    # mode for the first time.
    agent = create_ai_agent(parent: @user, agent_configuration: { "identity_prompt" => "hi" })
    agent.update_columns(agent_configuration: { "identity_prompt" => "hi" }) # ensure no "mode" key
    agent.reload

    agent.agent_configuration = agent.agent_configuration.merge("mode" => "external")
    assert agent.valid?, agent.errors.full_messages.to_s
  end

  test "system_agents scope returns only users with system_role set" do
    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio",
      user_type: "ai_agent",
      system_role: "trio",
      parent_id: nil,
    )
    user_agent = User.create!(
      email: "agent_#{SecureRandom.hex(4)}@example.com",
      name: "User Agent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    system_agents = User.system_agents
    assert_includes system_agents, trio
    assert_not_includes system_agents, user_agent
    assert_not_includes system_agents, @user
  end

  # === Global Roles Tests (HasGlobalRoles concern) ===

  test "app_admin? returns false by default" do
    assert_not @user.app_admin?
  end

  test "app_admin? returns true when app_admin column is true" do
    @user.update!(app_admin: true)
    assert @user.app_admin?
  end

  test "sys_admin? returns false by default" do
    assert_not @user.sys_admin?
  end

  test "sys_admin? returns true when sys_admin column is true" do
    @user.update!(sys_admin: true)
    assert @user.sys_admin?
  end

  test "add_global_role! sets app_admin to true" do
    assert_not @user.app_admin?
    @user.add_global_role!("app_admin")
    assert @user.app_admin?
  end

  test "add_global_role! sets sys_admin to true" do
    assert_not @user.sys_admin?
    @user.add_global_role!("sys_admin")
    assert @user.sys_admin?
  end

  test "add_global_role! raises error for invalid role" do
    error = assert_raises(RuntimeError) do
      @user.add_global_role!("invalid_role")
    end
    assert_match /Invalid global role/, error.message
  end

  test "remove_global_role! sets app_admin to false" do
    @user.update!(app_admin: true)
    assert @user.app_admin?
    @user.remove_global_role!("app_admin")
    assert_not @user.app_admin?
  end

  test "remove_global_role! sets sys_admin to false" do
    @user.update!(sys_admin: true)
    assert @user.sys_admin?
    @user.remove_global_role!("sys_admin")
    assert_not @user.sys_admin?
  end

  test "remove_global_role! raises error for invalid role" do
    error = assert_raises(RuntimeError) do
      @user.remove_global_role!("invalid_role")
    end
    assert_match /Invalid global role/, error.message
  end

  # === Activation Predicate Tests ===

  test "email_verified? returns false when there's no omni_auth_identity and no oauth identity" do
    assert_nil @user.omni_auth_identity
    assert_not @user.email_verified?
  end

  test "email_verified? returns false when the omni_auth_identity is unverified" do
    @user.find_or_create_omni_auth_identity!
    assert_not @user.email_verified?
  end

  test "email_verified? returns true when the omni_auth_identity is verified" do
    identity = @user.find_or_create_omni_auth_identity!
    identity.update!(email_confirmed_at: Time.current)
    assert @user.email_verified?
  end

  test "two_factor_enabled? is false when there is no identity" do
    assert_not @user.two_factor_enabled?
  end

  test "two_factor_enabled? is false when otp_enabled is false" do
    @user.find_or_create_omni_auth_identity!
    assert_not @user.two_factor_enabled?
  end

  test "two_factor_enabled? is true when otp_enabled is true" do
    identity = @user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!
    assert @user.two_factor_enabled?
  end

  test "fully_activated_for? returns true for a non-human user (collective_identity)" do
    # Collective identity users are system-generated and never need activation.
    ci_user = User.create!(email: "ci-#{SecureRandom.hex(4)}@example.com", name: "CI", user_type: "collective_identity")
    assert ci_user.fully_activated_for?(@tenant)
  end

  test "fully_activated_for? returns true for an AI agent (parent's activation is what matters)" do
    agent = create_ai_agent(parent: @user, name: "Agent #{SecureRandom.hex(4)}")
    assert agent.fully_activated_for?(@tenant),
           "expected AI agent to be considered activated regardless of its own state"
  end

  test "fully_activated_for? returns true for sys_admin even with no 2FA or unverified email" do
    @user.update!(sys_admin: true)
    assert @user.fully_activated_for?(@tenant),
           "expected sys_admin to bypass activation"
  end

  test "fully_activated_for? returns false when human is not a tenant member" do
    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}")
    # @user is in @tenant but NOT in other_tenant.
    assert_not @user.fully_activated_for?(other_tenant)
  end

  test "fully_activated_for? returns false when human's email isn't verified (and tenant requires it)" do
    identity = @user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret!
    identity.enable_otp!
    # email_confirmed_at left nil
    assert_not @user.fully_activated_for?(@tenant)
  end

  test "fully_activated_for? returns false when human has no 2FA (and tenant requires it)" do
    @user.find_or_create_omni_auth_identity!.update!(email_confirmed_at: Time.current)
    assert_not @user.fully_activated_for?(@tenant)
  end

  test "fully_activated_for? returns true when human has everything and tenant flags are default" do
    mark_activated!(@user)
    assert @user.fully_activated_for?(@tenant)
  end

  test "fully_activated_for? respects tenant flags — opted-out tenant doesn't require email/2FA" do
    @tenant.settings["require_verified_email"] = false
    @tenant.settings["require_2fa"] = false
    @tenant.save!
    # No email_confirmed_at, no 2FA — but the tenant doesn't require them.
    assert @user.fully_activated_for?(@tenant)
  end

  # === User Suspension Tests ===

  test "suspended? returns false by default" do
    assert_not @user.suspended?
  end

  test "suspended? returns true when suspended_at is set" do
    @user.update!(suspended_at: Time.current)
    assert @user.suspended?
  end

  test "suspend! sets suspended_at, suspended_by_id, and suspended_reason" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    @user.suspend!(by: admin, reason: "Policy violation")
    @user.reload

    assert @user.suspended?
    assert_equal admin.id, @user.suspended_by_id
    assert_equal "Policy violation", @user.suspended_reason
    assert @user.suspended_at.present?
  end

  test "unsuspend! clears suspension fields" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    @user.suspend!(by: admin, reason: "Policy violation")
    assert @user.suspended?

    @user.unsuspend!
    @user.reload

    assert_not @user.suspended?
    assert_nil @user.suspended_at
    assert_nil @user.suspended_by_id
    assert_nil @user.suspended_reason
  end

  test "suspended_by returns the user who suspended this user" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    @user.suspend!(by: admin, reason: "Policy violation")
    @user.reload

    assert_equal admin, @user.suspended_by
  end

  test "suspended_by returns nil when user is not suspended" do
    assert_nil @user.suspended_by
  end

  # === Suspension Security Tests ===

  test "suspend! soft-deletes all user API tokens" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create API tokens for the user
    token1 = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Token 1",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )
    token2 = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Token 2",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )

    assert token1.active?
    assert token2.active?

    @user.suspend!(by: admin, reason: "Policy violation")

    token1.reload
    token2.reload

    assert token1.deleted?, "Token 1 should be soft-deleted after user suspension"
    assert token2.deleted?, "Token 2 should be soft-deleted after user suspension"
  end

  test "suspend! suspends all direct ai_agents" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create ai_agents for the user
    ai_agent1 = User.create!(
      email: "ai_agent1_#{SecureRandom.hex(4)}@example.com",
      name: "AiAgent 1",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent1)

    ai_agent2 = User.create!(
      email: "ai_agent2_#{SecureRandom.hex(4)}@example.com",
      name: "AiAgent 2",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent2)

    assert_not ai_agent1.suspended?
    assert_not ai_agent2.suspended?

    @user.suspend!(by: admin, reason: "Policy violation")

    ai_agent1.reload
    ai_agent2.reload

    assert ai_agent1.suspended?, "AiAgent 1 should be suspended when parent is suspended"
    assert ai_agent2.suspended?, "AiAgent 2 should be suspended when parent is suspended"
    assert_equal admin.id, ai_agent1.suspended_by_id
    assert_equal "Parent user suspended: Policy violation", ai_agent1.suspended_reason
  end

  test "suspend! recursively suspends nested ai_agents" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create a chain: user -> ai_agent1 -> nested_ai_agent
    ai_agent1 = User.create!(
      email: "ai_agent1_#{SecureRandom.hex(4)}@example.com",
      name: "AiAgent 1",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent1)

    nested_ai_agent = User.create!(
      email: "nested_#{SecureRandom.hex(4)}@example.com",
      name: "Nested AiAgent",
      user_type: "ai_agent",
      parent_id: ai_agent1.id
    )
    @tenant.add_user!(nested_ai_agent)

    assert_not nested_ai_agent.suspended?

    @user.suspend!(by: admin, reason: "Policy violation")

    nested_ai_agent.reload

    assert nested_ai_agent.suspended?, "Nested ai_agent should be suspended when grandparent is suspended"
  end

  test "suspend! soft-deletes API tokens of all ai_agents recursively" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create a ai_agent with API tokens
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id
    )
    @tenant.add_user!(ai_agent)

    # Create nested ai_agent with API tokens
    nested_ai_agent = User.create!(
      email: "nested_#{SecureRandom.hex(4)}@example.com",
      name: "Nested AiAgent",
      user_type: "ai_agent",
      parent_id: ai_agent.id
    )
    @tenant.add_user!(nested_ai_agent)

    # Create tokens for ai_agents
    ai_agent_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "AiAgent Token",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )

    nested_token = ApiToken.create!(
      user: nested_ai_agent,
      tenant: @tenant,
      name: "Nested Token",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )

    assert ai_agent_token.active?
    assert nested_token.active?

    @user.suspend!(by: admin, reason: "Policy violation")

    ai_agent_token.reload
    nested_token.reload

    assert ai_agent_token.deleted?, "AiAgent's token should be soft-deleted when parent is suspended"
    assert nested_token.deleted?, "Nested ai_agent's token should be soft-deleted when grandparent is suspended"
  end

  test "suspend! soft-deletes API tokens across ALL tenants, not just current tenant" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create a second tenant and add the user to it
    other_tenant = Tenant.create!(name: "Other Tenant", subdomain: "other-#{SecureRandom.hex(4)}")
    other_tenant.add_user!(@user)

    # Create API tokens in both tenants
    token_in_current_tenant = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Current Tenant Token",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )

    token_in_other_tenant = ApiToken.create!(
      user: @user,
      tenant: other_tenant,
      name: "Other Tenant Token",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )

    assert token_in_current_tenant.active?
    assert token_in_other_tenant.active?

    # Suspend while in the context of the current tenant
    original_tenant_id = Tenant.current_id
    begin
      Tenant.current_id = @tenant.id
      @user.suspend!(by: admin, reason: "Policy violation")
    ensure
      Tenant.current_id = original_tenant_id
    end

    token_in_current_tenant.reload
    token_in_other_tenant.reload

    assert token_in_current_tenant.deleted?, "Token in current tenant should be soft-deleted"
    assert token_in_other_tenant.deleted?, "Token in OTHER tenant should also be soft-deleted"
  end

  # =========================================================================
  # DELEGATION TRUSTEE PERMISSION TESTS
  # These tests document the intended behavior for user-to-user delegation
  # via TrusteeGrant and representation sessions.
  # =========================================================================

  test "granted_trustee_grants returns permissions where user is granting_user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: other_user,
      permissions: { "create_notes" => true },
    )

    assert_includes @user.granted_trustee_grants, permission
    assert_not_includes other_user.granted_trustee_grants, permission
  end

  test "received_trustee_grants returns permissions where user is trustee_user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )

    assert_includes @user.received_trustee_grants, permission
    assert_not_includes other_user.received_trustee_grants, permission
  end

  test "pending_trustee_grant_requests returns only pending received permissions" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    pending_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: {},
    )

    third_user = create_user(email: "third_#{SecureRandom.hex(4)}@example.com", name: "Third User")
    @tenant.add_user!(third_user)
    accepted_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: third_user,
      trustee_user: @user,
      permissions: {},
    )
    accepted_permission.accept!

    pending_requests = @user.pending_trustee_grant_requests
    assert_includes pending_requests, pending_permission
    assert_not_includes pending_requests, accepted_permission
  end

  # === Delegation Representation Tests ===

  test "can_represent? returns true for trustee_user with active permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    permission.accept!

    # @user (trustee_user) should be able to represent other_user (granting_user)
    assert @user.can_represent?(other_user)
  end

  test "can_represent? returns false for trustee_user with pending permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    # Permission is pending, not accepted

    assert_not @user.can_represent?(other_user)
  end

  test "can_represent? returns false for trustee_user with revoked permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    permission.accept!
    permission.revoke!

    assert_not @user.can_represent?(other_user)
  end

  test "can_represent? returns false for trustee_user with expired permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
      expires_at: 1.hour.ago,
    )
    permission.update!(accepted_at: 2.hours.ago) # Simulate expired active permission

    assert_not @user.can_represent?(other_user)
  end

  test "can_represent? returns false when no permission exists" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    assert_not @user.can_represent?(other_user)
  end

  # === is_trusted_as? Tests ===
  # Note: is_trusted_as? now only applies to collective proxies (collective representation),
  # not user-to-user grants. User-to-user grants use can_represent? directly.

  test "is_trusted_as? returns false for regular users" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    # Regular users are not collective_identity users
    assert_not @user.is_trusted_as?(other_user)
  end

  test "is_trusted_as? returns true for collective identity when user is representative" do
    # Create a collective and make @user a representative
    collective = create_collective(tenant: @tenant, created_by: @user, handle: "test-collective-#{SecureRandom.hex(4)}")
    collective.add_user!(@user, roles: ["representative"])

    # Get the collective's identity user
    identity_user = collective.identity_user
    assert identity_user.collective_identity?
    assert identity_user.identity_collective.present?

    # @user should be trusted as the collective identity
    assert @user.is_trusted_as?(identity_user)
  end

  test "is_trusted_as? returns false for collective identity when user is not representative" do
    # Create a collective without @user as representative
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    collective = create_collective(tenant: @tenant, created_by: other_user, handle: "test-collective-#{SecureRandom.hex(4)}")

    # @user is not a member of the collective
    identity_user = collective.identity_user

    # @user should not be trusted as this collective's identity
    assert_not @user.is_trusted_as?(identity_user)
  end

  # === Auto-creation of TrusteeGrant for AiAgents ===

  test "creating a ai_agent auto-creates TrusteeGrant for parent" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    # Should auto-create a TrusteeGrant
    permission = TrusteeGrant.find_by(granting_user: ai_agent, trustee_user: @user)
    assert permission.present?, "TrusteeGrant should be auto-created when ai_agent is created"
    assert permission.active?, "Auto-created permission should be pre-accepted (active)"
    assert permission.accepted_at.present?
    # trustee_user is the parent (a regular person, not a collective_identity type)
    assert_equal @user, permission.trustee_user
    assert_not permission.trustee_user.collective_identity?
  end

  test "parent can represent ai_agent via auto-created TrusteeGrant" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )
    @tenant.add_user!(ai_agent)

    # Parent should be able to represent the ai_agent
    assert @user.can_represent?(ai_agent)
  end

  test "auto-created TrusteeGrant has all action permissions" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    permission = TrusteeGrant.find_by(granting_user: ai_agent, trustee_user: @user)
    assert permission.present?

    # Should have all grantable actions
    TrusteeGrant::GRANTABLE_ACTIONS.each do |action_name|
      assert permission.has_action_permission?(action_name), "Auto-created permission should have #{action_name} action"
    end
  end

  test "auto-created TrusteeGrant allows all collectives" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    permission = TrusteeGrant.find_by(granting_user: ai_agent, trustee_user: @user)
    assert permission.present?
    assert permission.allows_collective?(@collective)
  end

  # === Stripe Billing Tests ===

  # === Humans-free billing model ===

  test "counts_self_for_api_access? is false for a fresh human with no tokens" do
    fresh_tenant = create_tenant(subdomain: "api-bill-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "api-bill-#{SecureRandom.hex(4)}@example.com", name: "API #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    assert_not fresh_user.counts_self_for_api_access?
    assert_equal 0, fresh_user.billable_quantity
  end

  test "counts_self_for_api_access? is true once a human creates an active external token" do
    fresh_tenant = create_tenant(subdomain: "api-bill-token-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "api-bill-#{SecureRandom.hex(4)}@example.com", name: "API #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    create_api_token(user: fresh_user, tenant: fresh_tenant)

    assert fresh_user.counts_self_for_api_access?
    assert_equal 1, fresh_user.billable_quantity
  end

  test "counts_self_for_api_access? caps at 1 — flat surcharge regardless of token count" do
    fresh_tenant = create_tenant(subdomain: "api-bill-many-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "api-bill-#{SecureRandom.hex(4)}@example.com", name: "Many Tokens")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    3.times { create_api_token(user: fresh_user, tenant: fresh_tenant) }

    assert_equal 1, fresh_user.billable_quantity,
                 "owning multiple tokens should still only add +1 to billable_quantity"
  end

  test "counts_self_for_api_access? ignores deleted tokens" do
    fresh_tenant = create_tenant(subdomain: "api-bill-del-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "api-bill-#{SecureRandom.hex(4)}@example.com", name: "Deleter")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    token = create_api_token(user: fresh_user, tenant: fresh_tenant)
    token.delete!

    assert_not fresh_user.counts_self_for_api_access?
    assert_equal 0, fresh_user.billable_quantity
  end

  test "billing_exempt human with an active token is not billable for API access" do
    create_api_token(user: @user, tenant: @tenant)
    @user.update!(billing_exempt: true)

    assert_not @user.counts_self_for_paid_human_features?
    assert_equal 0, @user.billable_quantity
  end

  test "billing_exempt human with a notification webhook is not billable" do
    AutomationRule.unscoped.create!(
      tenant: @tenant,
      user: @user,
      created_by: @user,
      name: "Forward notifications",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" },
      enabled: true,
    )
    @user.update!(billing_exempt: true)

    assert_equal 0, @user.billable_quantity
  end

  test "billing_exempt on a human does not exempt their agents" do
    agent = create_ai_agent(parent: @user, name: "Still Billed")
    @tenant.add_user!(agent)
    @user.update!(billing_exempt: true)

    assert_equal 1, @user.billable_quantity,
                 "user-level exemption covers only the user's own +1, not their agents"
  end

  test "revoking billing_exempt on a human restores the API-access surcharge" do
    create_api_token(user: @user, tenant: @tenant)
    @user.update!(billing_exempt: true)
    assert_equal 0, @user.billable_quantity

    @user.update!(billing_exempt: false)
    assert_equal 1, @user.billable_quantity
  end

  test "human with only a notification webhook is billable (+1, same as a token)" do
    fresh_tenant = create_tenant(subdomain: "wh-bill-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "wh-bill-#{SecureRandom.hex(4)}@example.com", name: "Webhook #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    AutomationRule.unscoped.create!(
      tenant: fresh_tenant,
      user: fresh_user,
      created_by: fresh_user,
      name: "Forward notifications",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" },
      enabled: true,
    )

    assert_equal 1, fresh_user.billable_quantity
  end

  test "human with both token and webhook is still billed only once (same +1)" do
    fresh_tenant = create_tenant(subdomain: "wh-bill-both-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "wh-bill-both-#{SecureRandom.hex(4)}@example.com", name: "Both #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    create_api_token(user: fresh_user, tenant: fresh_tenant)
    AutomationRule.unscoped.create!(
      tenant: fresh_tenant,
      user: fresh_user,
      created_by: fresh_user,
      name: "Forward notifications",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" },
      enabled: true,
    )

    assert_equal 1, fresh_user.billable_quantity, "having both a token and a webhook still counts as +1"
  end

  test "counts_self_for_api_access? ignores expired tokens" do
    fresh_tenant = create_tenant(subdomain: "api-bill-exp-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "api-bill-#{SecureRandom.hex(4)}@example.com", name: "Expired")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    create_api_token(user: fresh_user, tenant: fresh_tenant, expires_at: 1.day.ago)

    assert_not fresh_user.counts_self_for_api_access?
    assert_equal 0, fresh_user.billable_quantity
  end

  test "counts_self_for_api_access? ignores internal (runner) tokens" do
    fresh_tenant = create_tenant(subdomain: "api-bill-int-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "api-bill-#{SecureRandom.hex(4)}@example.com", name: "Internal Only")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    # Internal tokens are per-task runner tokens issued by the system and
    # should not surcharge the user. Skip validation here — ApiToken requires
    # a context (AiAgentTaskRun/AutomationRuleRun) for internal tokens, which
    # is irrelevant to what this test is asserting (the billing filter).
    token = ApiToken.new(
      user: fresh_user,
      tenant: fresh_tenant,
      name: "Internal #{SecureRandom.hex(4)}",
      scopes: ["read:all"],
      expires_at: 1.hour.from_now,
      internal: true,
    )
    token.save!(validate: false)

    assert_not fresh_user.counts_self_for_api_access?
    assert_equal 0, fresh_user.billable_quantity
  end

  test "counts_self_for_api_access? is false for AI agents (their tokens belong to the agent itself)" do
    fresh_tenant = create_tenant(subdomain: "api-bill-agent-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    parent = create_user(email: "parent-#{SecureRandom.hex(4)}@example.com", name: "Parent")
    fresh_tenant.add_user!(parent)
    fresh_tenant.create_main_collective!(created_by: parent)

    Tenant.scope_thread_to_tenant(subdomain: fresh_tenant.subdomain)
    agent = create_ai_agent(parent: parent, name: "Agent #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(agent)
    Tenant.clear_thread_scope

    create_api_token(user: agent, tenant: fresh_tenant)

    assert_not agent.counts_self_for_api_access?,
               "AI agent tokens should not trigger the API-access surcharge"
  end

  test "billable_quantity is 0 for a sys_admin user even with tokens, agents, and collectives" do
    fresh_tenant = create_tenant(subdomain: "api-bill-sys-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    admin = create_user(email: "sys-#{SecureRandom.hex(4)}@example.com", name: "Sys")
    admin.update!(sys_admin: true)
    fresh_tenant.add_user!(admin)
    fresh_tenant.create_main_collective!(created_by: admin)

    create_api_token(user: admin, tenant: fresh_tenant)

    assert_not admin.counts_self_for_api_access?
    assert_equal 0, admin.billable_quantity,
                 "sys_admin users are platform operators and exempt from billing"
  end

  test "billable_quantity is 0 for an app_admin user even with tokens" do
    fresh_tenant = create_tenant(subdomain: "api-bill-app-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    admin = create_user(email: "app-#{SecureRandom.hex(4)}@example.com", name: "App")
    admin.update!(app_admin: true)
    fresh_tenant.add_user!(admin)
    fresh_tenant.create_main_collective!(created_by: admin)

    create_api_token(user: admin, tenant: fresh_tenant)

    assert_not admin.counts_self_for_api_access?
    assert_equal 0, admin.billable_quantity,
                 "app_admin users are platform operators and exempt from billing"
  end

  test "billable_quantity treats a human user as 0 (humans are free, agents and extra collectives are billed)" do
    fresh_tenant = create_tenant(subdomain: "fresh-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "fresh-#{SecureRandom.hex(4)}@example.com", name: "Fresh #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    assert_equal 0, fresh_user.billable_quantity,
                 "expected a fresh human with no agents or non-main collectives to contribute 0 to billable_quantity"
  end

  test "stripe_billing_setup? returns true for a fresh human with no billable resources" do
    fresh_tenant = create_tenant(subdomain: "fresh-setup-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "fresh-#{SecureRandom.hex(4)}@example.com", name: "Fresh #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    assert fresh_user.stripe_billing_setup?,
           "fresh humans should not be required to set up billing"
  end

  test "stripe_billing_setup? becomes false once a human creates a billable agent" do
    fresh_tenant = create_tenant(subdomain: "fresh-agent-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "fresh-#{SecureRandom.hex(4)}@example.com", name: "Fresh #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)
    assert fresh_user.stripe_billing_setup?, "sanity check: free before creating anything"

    Tenant.scope_thread_to_tenant(subdomain: fresh_tenant.subdomain)
    agent = create_ai_agent(parent: fresh_user, name: "Agent #{SecureRandom.hex(4)}")
    fresh_tenant.add_user!(agent)

    assert_not fresh_user.reload.stripe_billing_setup?,
               "creating a billable agent should require billing setup"
    assert_equal 1, fresh_user.billable_quantity
  end

  test "stripe_billing_setup? returns true when user has active stripe customer" do
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
      active: true,
    )
    assert @user.reload.stripe_billing_setup?
  end

  test "stripe_billing_setup? returns false when user has no stripe customer" do
    @collective.update!(tier: Collective::TIER_PAID) # make @collective paid_tier so user has a billable resource
    assert_not @user.stripe_billing_setup?
  end

  test "stripe_billing_setup? returns false when stripe customer is inactive" do
    @collective.update!(tier: Collective::TIER_PAID)
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
      active: false,
    )
    assert_not @user.reload.stripe_billing_setup?
  end

  test "requires_stripe_billing? returns true when flag enabled and billing not set up" do
    enable_stripe_billing_flag!(@tenant)
    @collective.update!(tier: Collective::TIER_PAID)
    assert @user.requires_stripe_billing?(@tenant)
  end

  test "requires_stripe_billing? returns false when flag disabled" do
    non_billing_tenant = create_tenant(subdomain: "no-billing-#{SecureRandom.hex(4)}")
    non_billing_tenant.add_user!(@user)
    assert_not @user.requires_stripe_billing?(non_billing_tenant)
  end

  test "requires_stripe_billing? returns false when billing already set up" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
      active: true,
    )
    @user.reload
    assert_not @user.requires_stripe_billing?(@tenant)
  end

  test "stripe_billing_setup? returns true when billing_exempt and all resources exempt" do
    @user.update!(billing_exempt: true)
    # @collective is created by @user and is non-main, so it's billable
    # Exempt it too so billable_quantity is 0
    @collective.update!(billing_exempt: true)
    assert @user.stripe_billing_setup?
  end

  test "stripe_billing_setup? returns false when billing_exempt but has non-exempt resources" do
    @user.update!(billing_exempt: true)
    # @collective is non-exempt; make it paid_tier so it counts as a billable resource
    @collective.update!(tier: Collective::TIER_PAID)
    assert_not @user.stripe_billing_setup?
  end

  test "active_billable_agent_count counts non-archived non-suspended agents" do
    agent1 = create_ai_agent(parent: @user, name: "Agent 1")
    @tenant.add_user!(agent1)
    agent2 = create_ai_agent(parent: @user, name: "Agent 2")
    @tenant.add_user!(agent2)

    assert_equal 2, @user.active_billable_agent_count
  end

  test "active_billable_agent_count excludes archived agents" do
    agent1 = create_ai_agent(parent: @user, name: "Active Agent")
    @tenant.add_user!(agent1)
    agent2 = create_ai_agent(parent: @user, name: "Archived Agent")
    @tenant.add_user!(agent2)
    agent2.tenant_user = agent2.tenant_users.find_by(tenant_id: @tenant.id)
    agent2.archive!

    assert_equal 1, @user.active_billable_agent_count
  end

  test "active_billable_agent_count excludes suspended agents" do
    agent1 = create_ai_agent(parent: @user, name: "Active Agent")
    @tenant.add_user!(agent1)
    agent2 = create_ai_agent(parent: @user, name: "Suspended Agent")
    @tenant.add_user!(agent2)
    agent2.update!(suspended_at: Time.current)

    assert_equal 1, @user.active_billable_agent_count
  end

  test "active_billable_agent_count returns 0 when no agents" do
    assert_equal 0, @user.active_billable_agent_count
  end

  # === Collective Billing Tests ===

  test "active_billable_collective_count counts non-main collectives on the paid tier" do
    @tenant.update!(main_collective_id: @collective.id) # make it main so we start from 0
    extra = Collective.create!(tenant: @tenant, created_by: @user, name: "Extra #{SecureRandom.hex(4)}", handle: "extra-#{SecureRandom.hex(4)}")
    assert_equal 0, @user.active_billable_collective_count,
                 "non-main collective on free tier should not count"
    upgrade_collective_to_paid!(extra)
    assert_equal 1, @user.active_billable_collective_count,
                 "non-main collective on paid tier should count"
  end

  test "active_billable_collective_count is 1 per paid collective regardless of how many paid features are enabled" do
    @tenant.update!(main_collective_id: @collective.id)
    extra = Collective.create!(tenant: @tenant, created_by: @user, name: "Extra #{SecureRandom.hex(4)}", handle: "extra-#{SecureRandom.hex(4)}")
    upgrade_collective_to_paid!(extra)
    create_billable_automation(extra)
    @tenant.enable_feature_flag!("trio")
    extra.enable_feature_flag!("trio")
    assert_equal 1, @user.active_billable_collective_count,
                 "paid collective with automation + trio is still 1"
  end

  test "active_billable_collective_count excludes main collective even on paid tier" do
    @tenant.update!(main_collective_id: @collective.id)
    upgrade_collective_to_paid!(@collective)
    assert_equal 0, @user.active_billable_collective_count
  end

  test "active_billable_collective_count excludes archived paid collectives" do
    @tenant.update!(main_collective_id: @collective.id)
    extra = Collective.create!(tenant: @tenant, created_by: @user, name: "Archived #{SecureRandom.hex(4)}", handle: "archived-#{SecureRandom.hex(4)}")
    upgrade_collective_to_paid!(extra)
    assert_equal 1, @user.active_billable_collective_count,
                 "sanity check: paid collective counts before archive"
    extra.archive!(actor: @user)
    assert_equal 0, @user.active_billable_collective_count,
                 "archive must drop the collective out of the billable count"
  end

  test "active_billable_collective_count excludes collectives created by other users" do
    @tenant.update!(main_collective_id: @collective.id)
    other = create_user(email: "other-#{SecureRandom.hex(4)}@example.com", name: "Other User #{SecureRandom.hex(4)}")
    @tenant.add_user!(other)
    other_collective = Collective.create!(tenant: @tenant, created_by: other, name: "Other #{SecureRandom.hex(4)}", handle: "other-#{SecureRandom.hex(4)}")
    upgrade_collective_to_paid!(other_collective, owner: other)
    assert_equal 0, @user.active_billable_collective_count
  end

  test "active_billable_collective_count excludes billing_exempt collectives" do
    @tenant.update!(main_collective_id: @collective.id)
    extra = Collective.create!(tenant: @tenant, created_by: @user, name: "Exempt #{SecureRandom.hex(4)}", handle: "exempt-#{SecureRandom.hex(4)}", billing_exempt: true)
    upgrade_collective_to_paid!(extra)
    assert_equal 0, @user.active_billable_collective_count
  end

  test "active_billable_collective_count counts paid-tier private workspaces" do
    # @user already has a workspace from setup
    workspace = @user.private_workspace
    assert workspace, "user should have a workspace"

    @tenant.update!(main_collective_id: @collective.id)
    assert_equal 0, @user.active_billable_collective_count,
                 "free-tier workspace should not count"

    upgrade_collective_to_paid!(workspace, owner: @user)
    assert_equal 1, @user.reload.active_billable_collective_count,
                 "paid-tier workspace should count"
  end

  test "active_billable_collective_count works correctly when Tenant.current_id and Collective.current_id are set" do
    # Regression: in a request context with Tenant.current_id/Collective.current_id set,
    # the cross-collective lookup must bypass default_scope so paid collectives in
    # other tenants/collectives still count toward the user's billable quantity.
    @tenant.update!(main_collective_id: @collective.id) # collective becomes main; create new paid one
    paid = Collective.create!(tenant: @tenant, created_by: @user, name: "Paid #{SecureRandom.hex(4)}", handle: "paid-#{SecureRandom.hex(4)}")
    upgrade_collective_to_paid!(paid)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_equal 1, @user.active_billable_collective_count,
                 "cross-collective lookup must bypass default_scope so other collectives count"
  ensure
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  test "active_billable_collective_count excludes chat collectives even when paid_tier" do
    @tenant.update!(main_collective_id: @collective.id)
    chat = Collective.create!(tenant: @tenant, created_by: @user, name: "Chat #{SecureRandom.hex(4)}", handle: "chat-#{SecureRandom.hex(4)}", collective_type: "chat")
    upgrade_collective_to_paid!(chat)
    assert chat.paid_tier?, "sanity check: chat collective is paid_tier"
    assert_equal 0, @user.active_billable_collective_count,
                 "chat collectives are excluded by the billable_types scope"
  end

  private

  def enable_stripe_billing_flag!(tenant)
    # Temporarily set app_enabled to true for stripe_billing in the cached config
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  def create_billable_automation(collective)
    AutomationRule.create!(
      tenant: collective.tenant,
      collective: collective,
      created_by: collective.created_by,
      name: "Rule #{SecureRandom.hex(4)}",
      trigger_type: "manual",
      trigger_config: { "inputs" => {} },
      conditions: [],
      actions: {},
      enabled: true
    )
  end

  def create_api_token(user:, tenant:, name: nil, scopes: ["read:all"], expires_at: 1.year.from_now)
    ApiToken.create!(
      user: user,
      tenant: tenant,
      name: name || "Token #{SecureRandom.hex(4)}",
      scopes: scopes,
      expires_at: expires_at,
    )
  end

  # ==========================================
  # Session Revocation Tests
  # ==========================================

  test "revoke_all_sessions! sets sessions_revoked_at" do
    user = create_user(email: "revoke-test-#{SecureRandom.hex(4)}@example.com", name: "Revoke Test")

    assert_nil user.sessions_revoked_at

    user.revoke_all_sessions!
    user.reload

    assert_not_nil user.sessions_revoked_at
    assert_in_delta Time.current, user.sessions_revoked_at, 5
  end

  test "revoke_all_sessions! deletes all API tokens" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create API tokens for the user
    token1 = ApiToken.create!(user: user, name: "Token 1", tenant: tenant, scopes: ["read:all"])
    token2 = ApiToken.create!(user: user, name: "Token 2", tenant: tenant, scopes: ["read:all"])

    user.revoke_all_sessions!

    token1.reload
    token2.reload
    assert_not_nil token1.deleted_at
    assert_not_nil token2.deleted_at
  end

  test "revoke_all_sessions! deletes child AI agent tokens" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    ai_agent = User.create!(
      email: "agent-#{SecureRandom.hex(4)}@example.com",
      name: "Child Agent",
      user_type: "ai_agent",
      parent_id: user.id,
    )
    tenant.add_user!(ai_agent)
    agent_token = ApiToken.create!(user: ai_agent, name: "Agent Token", tenant: tenant, scopes: ["read:all"])

    user.revoke_all_sessions!

    agent_token.reload
    assert_not_nil agent_token.deleted_at
  end

  # =========================================================================
  # Private Workspace tests
  # =========================================================================

  test "human user gets private workspace when added to tenant" do
    tenant = create_tenant(subdomain: "pw-human-#{SecureRandom.hex(4)}")
    user = create_user
    tenant.add_user!(user)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)

    workspace = user.private_workspace
    assert workspace, "Human user should have a private workspace"
    assert workspace.private_workspace?
    assert workspace.user_is_member?(user)
    assert_equal "Private Workspace", workspace.name
  end

  test "ai_agent gets private workspace when added to tenant" do
    tenant = create_tenant(subdomain: "pw-agent-#{SecureRandom.hex(4)}")
    parent = create_user
    tenant.add_user!(parent)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)

    agent = create_ai_agent(parent: parent, name: "Memory Agent")
    tenant.add_user!(agent)

    workspace = agent.private_workspace
    assert workspace, "AI agent should have a private workspace"
    assert workspace.private_workspace?
    assert workspace.user_is_member?(agent)
    # Parent should NOT be a member
    assert_not workspace.user_is_member?(parent)
  end

  test "collective_identity user does not get private workspace" do
    tenant = create_tenant(subdomain: "pw-ci-#{SecureRandom.hex(4)}")
    user = create_user
    collective = Collective.create!(
      tenant: tenant,
      created_by: user,
      name: "Identity Test",
      handle: "ci-test-#{SecureRandom.hex(4)}",
    )
    identity_user = collective.identity_user
    assert identity_user.collective_identity?
    assert_nil identity_user.private_workspace
  end

  test "private_workspace returns nil for collective_identity users" do
    user = create_user(user_type: "collective_identity")
    assert_nil user.private_workspace
  end

  test "archiving user archives private workspace" do
    tenant = create_tenant(subdomain: "pw-archive-#{SecureRandom.hex(4)}")
    user = create_user
    tu = tenant.add_user!(user)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    user.tenant_user = tu

    workspace = user.private_workspace
    assert workspace
    assert_not workspace.archived?

    user.archive!
    workspace.reload
    assert workspace.archived?, "Workspace should be archived when user is archived"
  end

  test "archiving user with paid private workspace syncs Stripe subscription quantity" do
    tenant = create_tenant(subdomain: "pw-arch-sync-#{SecureRandom.hex(4)}")
    tenant.enable_feature_flag!("stripe_billing")
    user = create_user
    tu = tenant.add_user!(user)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    user.tenant_user = tu

    workspace = user.private_workspace
    assert workspace
    upgrade_collective_to_paid!(workspace, owner: user)

    synced_with = nil
    StripeService.stub(:sync_subscription_quantity!, ->(arg) { synced_with = arg; StripeService::SyncResult.new(success: true, charged_cents: nil) }) do
      user.archive!
    end

    assert_equal user.id, synced_with&.id,
                 "archiving a user must sync Stripe via the workspace archive cascade"
  ensure
    Tenant.clear_thread_scope
  end

  test "unarchiving user unarchives private workspace" do
    tenant = create_tenant(subdomain: "pw-unarch-#{SecureRandom.hex(4)}")
    user = create_user
    tu = tenant.add_user!(user)
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    user.tenant_user = tu

    user.archive!
    workspace = user.reload.private_workspace
    assert workspace.archived?

    user.unarchive!
    workspace.reload
    assert_not workspace.archived?, "Workspace should be unarchived when user is unarchived"
  end

  test "private workspace with no paid features is not counted in billable_quantity" do
    # @user already has a workspace from setup. Under the free/paid tier model,
    # workspaces are no longer billing_exempt by default — they bill the same
    # as standard collectives. A fresh workspace has no paid features active,
    # so paid_tier? is false and it doesn't count.
    workspace = @user.private_workspace
    assert workspace, "User should have a workspace"
    assert_not workspace.billing_exempt?, "workspaces no longer default to billing_exempt"
    assert workspace.free_tier?, "fresh workspace has no paid features"

    assert_equal 0, @user.active_billable_collective_count,
                 "fresh workspace should contribute 0 to billable_quantity"
  end

  # === Avatar Color Tests ===

  test "human user avatar_color is the human color" do
    assert_equal HasImage::HUMAN_AVATAR_COLOR, @user.avatar_color
  end

  test "ai agent user avatar_color is the ai agent color" do
    agent = create_ai_agent(parent: @user, name: "Agent-#{SecureRandom.hex(2)}")
    assert_equal HasImage::AI_AGENT_AVATAR_COLOR, agent.avatar_color
  end

  test "collective_identity user avatar_color is the collective color" do
    collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Identity Test",
      handle: "ident-test-#{SecureRandom.hex(4)}",
    )
    identity = collective.identity_user
    assert identity.present?
    assert_equal HasImage::COLLECTIVE_AVATAR_COLOR, identity.avatar_color
  end

  # === collective_identity backing-Collective invariant ===

  test "Collective creation succeeds even though identity_user has no backing Collective at the moment of User.create!" do
    # `Collective#create_identity_user!` instantiates the identity User before
    # the Collective has been saved with identity_user_id; the on: :update
    # qualifier on the validation keeps this legitimate path open.
    tenant = create_tenant(subdomain: "ci-create-#{SecureRandom.hex(4)}")
    human = create_user(email: "hum-ci-#{SecureRandom.hex(4)}@example.com")
    tenant.add_user!(human)
    assert_nothing_raised do
      Collective.create!(tenant: tenant, created_by: human, name: "C", handle: "c-#{SecureRandom.hex(4)}")
    end
  end

  test "updating an orphan collective_identity user fails with the backing-Collective validation" do
    # Manufacture the corruption case by creating the User directly (bypassing
    # the Collective flow). Subsequent update must be rejected.
    orphan = User.create!(
      email: "orphan-ci-#{SecureRandom.hex(4)}@example.com",
      name: "Orphan CI",
      user_type: "collective_identity",
    )
    orphan.name = "Renamed"
    assert_not orphan.valid?
    assert_match(/must have a backing Collective/, orphan.errors[:base].join)
  end

  test "updating a collective_identity user with a backing Collective passes validation" do
    tenant = create_tenant(subdomain: "ci-upd-#{SecureRandom.hex(4)}")
    human = create_user(email: "hum-ci-upd-#{SecureRandom.hex(4)}@example.com")
    tenant.add_user!(human)
    collective = Collective.create!(tenant: tenant, created_by: human, name: "Ok", handle: "ok-#{SecureRandom.hex(4)}")
    identity = collective.identity_user
    identity.name = "Renamed"
    assert identity.valid?, identity.errors.full_messages.to_sentence
  end
end

