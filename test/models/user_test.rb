require "test_helper"

class UserTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "user-test-#{SecureRandom.hex(4)}")
    @user = create_user(email: "usertest_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @collective = create_collective(tenant: @tenant, created_by: @user, handle: "user-collective-#{SecureRandom.hex(4)}")
    @collective.add_user!(@user)
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
      name: "Invite Studio",
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
    # Set the thread tenant context for the scope
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain) do
      @tenant.create_main_collective!(created_by: @user)
      main_collective = @tenant.main_collective
      main_collective.add_user!(@user)

      studios = @user.collectives_minus_main
      assert_not_includes studios, main_collective
      assert_includes studios, @collective
    end
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

  test "can_represent? returns true for identity user representing their own studio" do
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

  test "can_represent? returns false for non-member of studio" do
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

  test "can_represent? returns true for representative representing studio identity" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    identity_user = @collective.identity_user
    assert @user.can_represent?(identity_user)
  end

  test "can_represent? returns false for non-representative trying to represent studio identity" do
    identity_user = @collective.identity_user
    assert_not @user.can_represent?(identity_user)
  end

  test "can_represent? returns true for studio identity when any_member_can_represent is enabled" do
    @collective.settings['any_member_can_represent'] = true
    @collective.save!
    identity_user = @collective.identity_user
    assert @user.can_represent?(identity_user)
  end

  test "can_represent? returns false for non-member trying to represent studio identity" do
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
  # Note: is_trusted_as? now only applies to collective proxies (studio representation),
  # not user-to-user grants. User-to-user grants use can_represent? directly.

  test "is_trusted_as? returns false for regular users" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    # Regular users are not collective_identity users
    assert_not @user.is_trusted_as?(other_user)
  end

  test "is_trusted_as? returns true for collective identity when user is representative" do
    # Create a studio and make @user a representative
    studio = create_collective(tenant: @tenant, created_by: @user, handle: "test-studio-#{SecureRandom.hex(4)}")
    studio.add_user!(@user, roles: ["representative"])

    # Get the studio's identity user
    identity_user = studio.identity_user
    assert identity_user.collective_identity?
    assert identity_user.identity_collective.present?

    # @user should be trusted as the collective identity
    assert @user.is_trusted_as?(identity_user)
  end

  test "is_trusted_as? returns false for collective identity when user is not representative" do
    # Create a studio without @user as representative
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    studio = create_collective(tenant: @tenant, created_by: other_user, handle: "test-studio-#{SecureRandom.hex(4)}")

    # @user is not a member of the studio
    identity_user = studio.identity_user

    # @user should not be trusted as this studio's identity
    assert_not @user.is_trusted_as?(identity_user)
  end

  # === Auto-creation of TrusteeGrant for AiAgents (Phase 7) ===

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

  test "auto-created TrusteeGrant allows all studios" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )

    permission = TrusteeGrant.find_by(granting_user: ai_agent, trustee_user: @user)
    assert permission.present?
    assert permission.allows_studio?(@collective)
  end
end

