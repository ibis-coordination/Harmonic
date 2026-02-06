require "test_helper"

class UserTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "user-test-#{SecureRandom.hex(4)}")
    @user = create_user(email: "usertest_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "user-superagent-#{SecureRandom.hex(4)}")
    @superagent.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  # === Basic Creation Tests ===

  test "User.create works" do
    user = User.create!(
      email: "#{SecureRandom.hex(8)}@example.com",
      name: 'Test Person',
      user_type: 'person'
    )
    assert user.persisted?
    assert_equal 'Test Person', user.name
    assert_equal 'person', user.user_type
    assert user.email.present?
  end

  test "User requires email" do
    user = User.new(name: "No Email", user_type: "person")
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "User requires name" do
    user = User.new(email: "noemail@example.com", user_type: "person")
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
    user = User.new(user_type: "person")
    assert user.person?
    assert_not user.subagent?
    assert_not user.trustee?
  end

  test "subagent? returns true for subagent user type" do
    parent = create_user
    user = User.new(user_type: "subagent", parent_id: parent.id)
    assert user.subagent?
    assert_not user.person?
    assert_not user.trustee?
  end

  test "trustee? returns true for trustee user type" do
    user = User.new(user_type: "trustee")
    assert user.trustee?
    assert_not user.person?
    assert_not user.subagent?
  end

  # === Association Tests ===

  test "user has many tenant_users" do
    assert @user.tenant_users.any?
    assert_includes @user.tenants, @tenant
  end

  test "user has many superagent_members" do
    assert @user.superagent_members.any?
    assert_includes @user.superagents, @superagent
  end

  test "user can have multiple tenants" do
    tenant2 = create_tenant(subdomain: "user-test2-#{SecureRandom.hex(4)}")
    tenant2.add_user!(@user)

    # Verify user is in second tenant by querying unscoped
    tenant2_membership = TenantUser.unscoped.find_by(user_id: @user.id, tenant_id: tenant2.id)
    assert tenant2_membership.present?, "User should be added to tenant2"
  end

  test "user can have subagent users as children" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Subagent User",
      user_type: "subagent",
      parent_id: @user.id
    )

    assert_includes @user.subagents, subagent
    assert_equal @user.id, subagent.parent_id
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

  test "display_name_with_parent for subagent includes parent name" do
    @user.tenant_user.update!(display_name: "Bob")
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Alice Bot",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent)
    subagent.tenant_user.update!(display_name: "Alice")
    assert_equal "Alice (subagent of Bob)", subagent.display_name_with_parent
  end

  test "parent returns parent user for subagent" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Subagent",
      user_type: "subagent",
      parent_id: @user.id
    )
    assert_equal @user, subagent.parent
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

  test "parent can edit subagent child" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Subagent User",
      user_type: "subagent",
      parent_id: @user.id
    )
    assert @user.can_edit?(subagent)
  end

  # === Invite Acceptance Tests ===

  test "user can accept invite for themselves" do
    new_superagent = Superagent.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Invite Studio",
      handle: "invite-superagent-#{SecureRandom.hex(4)}"
    )
    invite = Invite.create!(
      tenant: @tenant,
      superagent: new_superagent,
      created_by: @user,
      invited_user: @user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    assert_not new_superagent.user_is_member?(@user)
    @user.accept_invite!(invite)
    assert new_superagent.user_is_member?(@user)
  end

  test "user cannot accept invite for another user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    # Add to tenant with unique handle
    TenantUser.create!(tenant: @tenant, user: other_user, handle: "other-user-#{SecureRandom.hex(4)}")

    invite = Invite.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      invited_user: other_user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    assert_raises RuntimeError, "Cannot accept invite for another user" do
      @user.accept_invite!(invite)
    end
  end

  # === Superagents Minus Main Tests ===

  test "superagents_minus_main excludes main superagent" do
    # Set the thread tenant context for the scope
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain) do
      @tenant.create_main_superagent!(created_by: @user)
      main_superagent = @tenant.main_superagent
      main_superagent.add_user!(@user)

      studios = @user.superagents_minus_main
      assert_not_includes studios, main_superagent
      assert_includes studios, @superagent
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

  # === Trustee User Tests ===

  test "superagent_trustee? returns true for superagent's trustee user" do
    trustee = @superagent.trustee_user
    assert trustee.trustee?
    assert trustee.superagent_trustee?
  end

  test "superagent_trustee? returns false for non-superagent trustee" do
    # A trustee created via TrusteeGrant is not a superagent trustee
    trustee = User.create!(
      email: "#{SecureRandom.uuid}@not-a-real-email.com",
      name: "Non-superagent Trustee",
      user_type: "trustee",
    )
    assert trustee.trustee?
    assert_not trustee.superagent_trustee?
  end

  test "trustee_superagent returns associated superagent" do
    trustee = @superagent.trustee_user
    assert_equal @superagent, trustee.trustee_superagent
  end

  test "trustee_superagent returns nil for person user" do
    assert_nil @user.trustee_superagent
  end

  test "trustee_superagent returns nil for non-superagent trustee" do
    trustee = User.create!(
      email: "#{SecureRandom.uuid}@not-a-real-email.com",
      name: "Non-superagent Trustee",
      user_type: "trustee",
    )
    assert_nil trustee.trustee_superagent
  end

  # === Impersonation Authorization Tests ===

  test "can_impersonate? returns true for parent impersonating subagent" do
    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)
    assert @user.can_impersonate?(subagent)
  end

  test "can_impersonate? returns false for archived subagent" do
    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)
    subagent.tenant_user.archive!
    assert_not @user.can_impersonate?(subagent)
  end

  test "can_impersonate? returns false for non-parent user" do
    other_parent = create_user(email: "other_parent_#{SecureRandom.hex(4)}@example.com", name: "Other Parent")
    @tenant.add_user!(other_parent)
    subagent = create_subagent(parent: other_parent, name: "Other Subagent")
    @tenant.add_user!(subagent)
    assert_not @user.can_impersonate?(subagent)
  end

  test "can_impersonate? returns true for representative impersonating studio trustee" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    trustee = @superagent.trustee_user
    assert @user.can_impersonate?(trustee)
  end

  test "can_impersonate? returns false for non-representative trying to impersonate studio trustee" do
    trustee = @superagent.trustee_user
    assert_not @user.can_impersonate?(trustee)
  end

  test "can_impersonate? returns true when any_member_can_represent is enabled" do
    @superagent.settings['any_member_can_represent'] = true
    @superagent.save!
    trustee = @superagent.trustee_user
    assert @user.can_impersonate?(trustee)
  end

  test "can_impersonate? returns false for non-member trying to impersonate studio trustee" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    trustee = @superagent.trustee_user
    assert_not other_user.can_impersonate?(trustee)
  end

  # === Representation Authorization Tests ===

  test "can_represent? returns true for trustee user representing their own studio" do
    trustee = @superagent.trustee_user
    assert trustee.can_represent?(@superagent)
  end

  test "can_represent? returns true for user with representative role" do
    @superagent.superagent_members.find_by(user: @user).add_role!('representative')
    assert @user.can_represent?(@superagent)
  end

  test "can_represent? returns false for user without representative role" do
    assert_not @user.can_represent?(@superagent)
  end

  test "can_represent? returns true when any_member_can_represent is enabled" do
    @superagent.settings['any_member_can_represent'] = true
    @superagent.save!
    assert @user.can_represent?(@superagent)
  end

  test "can_represent? returns false for non-member of studio" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User For Rep")
    @tenant.add_user!(other_user)
    assert_not other_user.can_represent?(@superagent)
  end

  test "can_represent? with user argument delegates to can_impersonate?" do
    subagent = create_subagent(parent: @user, name: "Test Subagent For Rep")
    @tenant.add_user!(subagent)
    assert @user.can_represent?(subagent)
    assert_equal @user.can_impersonate?(subagent), @user.can_represent?(subagent)
  end

  # === Subagent Validation Tests ===

  test "subagent must have parent_id" do
    subagent = User.new(
      email: "subagent@example.com",
      name: "Subagent Without Parent",
      user_type: "subagent",
      parent_id: nil,
    )
    assert_not subagent.valid?
    assert_includes subagent.errors[:parent_id], "must be set for subagent users"
  end

  test "person cannot have parent_id" do
    person = User.new(
      email: "person@example.com",
      name: "Person With Parent",
      user_type: "person",
      parent_id: @user.id,
    )
    assert_not person.valid?
    assert_includes person.errors[:parent_id], "can only be set for subagent users"
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

  test "suspend! suspends all direct subagents" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create subagents for the user
    subagent1 = User.create!(
      email: "subagent1_#{SecureRandom.hex(4)}@example.com",
      name: "Subagent 1",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent1)

    subagent2 = User.create!(
      email: "subagent2_#{SecureRandom.hex(4)}@example.com",
      name: "Subagent 2",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent2)

    assert_not subagent1.suspended?
    assert_not subagent2.suspended?

    @user.suspend!(by: admin, reason: "Policy violation")

    subagent1.reload
    subagent2.reload

    assert subagent1.suspended?, "Subagent 1 should be suspended when parent is suspended"
    assert subagent2.suspended?, "Subagent 2 should be suspended when parent is suspended"
    assert_equal admin.id, subagent1.suspended_by_id
    assert_equal "Parent user suspended: Policy violation", subagent1.suspended_reason
  end

  test "suspend! recursively suspends nested subagents" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create a chain: user -> subagent1 -> nested_subagent
    subagent1 = User.create!(
      email: "subagent1_#{SecureRandom.hex(4)}@example.com",
      name: "Subagent 1",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent1)

    nested_subagent = User.create!(
      email: "nested_#{SecureRandom.hex(4)}@example.com",
      name: "Nested Subagent",
      user_type: "subagent",
      parent_id: subagent1.id
    )
    @tenant.add_user!(nested_subagent)

    assert_not nested_subagent.suspended?

    @user.suspend!(by: admin, reason: "Policy violation")

    nested_subagent.reload

    assert nested_subagent.suspended?, "Nested subagent should be suspended when grandparent is suspended"
  end

  test "suspend! soft-deletes API tokens of all subagents recursively" do
    admin = create_user(email: "admin_#{SecureRandom.hex(4)}@example.com", name: "Admin User")
    @tenant.add_user!(admin)

    # Create a subagent with API tokens
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Subagent",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent)

    # Create nested subagent with API tokens
    nested_subagent = User.create!(
      email: "nested_#{SecureRandom.hex(4)}@example.com",
      name: "Nested Subagent",
      user_type: "subagent",
      parent_id: subagent.id
    )
    @tenant.add_user!(nested_subagent)

    # Create tokens for subagents
    subagent_token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Subagent Token",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )

    nested_token = ApiToken.create!(
      user: nested_subagent,
      tenant: @tenant,
      name: "Nested Token",
      scopes: ["read:all"],
      expires_at: 1.year.from_now
    )

    assert subagent_token.active?
    assert nested_token.active?

    @user.suspend!(by: admin, reason: "Policy violation")

    subagent_token.reload
    nested_token.reload

    assert subagent_token.deleted?, "Subagent's token should be soft-deleted when parent is suspended"
    assert nested_token.deleted?, "Nested subagent's token should be soft-deleted when grandparent is suspended"
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
      trusted_user: other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )

    assert_includes @user.granted_trustee_grants, permission
    assert_not_includes other_user.granted_trustee_grants, permission
  end

  test "received_trustee_grants returns permissions where user is trusted_user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
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
      trusted_user: @user,
      relationship_phrase: "pending",
      permissions: {},
    )

    third_user = create_user(email: "third_#{SecureRandom.hex(4)}@example.com", name: "Third User")
    @tenant.add_user!(third_user)
    accepted_permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: third_user,
      trusted_user: @user,
      relationship_phrase: "accepted",
      permissions: {},
    )
    accepted_permission.accept!

    pending_requests = @user.pending_trustee_grant_requests
    assert_includes pending_requests, pending_permission
    assert_not_includes pending_requests, accepted_permission
  end

  # === Delegation Representation Tests ===

  test "can_represent? returns true for trusted_user with active permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!

    # @user (trusted_user) should be able to represent other_user (granting_user)
    assert @user.can_represent?(other_user)
  end

  test "can_represent? returns false for trusted_user with pending permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    # Permission is pending, not accepted

    assert_not @user.can_represent?(other_user)
  end

  test "can_represent? returns false for trusted_user with revoked permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!
    permission.revoke!

    assert_not @user.can_represent?(other_user)
  end

  test "can_represent? returns false for trusted_user with expired permission" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
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

  # === Auto-creation of TrusteeGrant for Subagents (Phase 7) ===

  test "creating a subagent auto-creates TrusteeGrant for parent" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Test Subagent",
      user_type: "subagent",
      parent_id: @user.id,
    )

    # Should auto-create a TrusteeGrant
    permission = TrusteeGrant.find_by(granting_user: subagent, trusted_user: @user)
    assert permission.present?, "TrusteeGrant should be auto-created when subagent is created"
    assert permission.active?, "Auto-created permission should be pre-accepted (active)"
    assert permission.accepted_at.present?
    assert permission.trustee_user.trustee?
  end

  test "parent can represent subagent via auto-created TrusteeGrant" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Test Subagent",
      user_type: "subagent",
      parent_id: @user.id,
    )
    @tenant.add_user!(subagent)

    # Parent should be able to represent the subagent
    assert @user.can_represent?(subagent)
  end

  test "auto-created TrusteeGrant has all capabilities" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Test Subagent",
      user_type: "subagent",
      parent_id: @user.id,
    )

    permission = TrusteeGrant.find_by(granting_user: subagent, trusted_user: @user)
    assert permission.present?

    # Should have all capabilities
    TrusteeGrant::CAPABILITIES.keys.each do |capability|
      assert permission.has_capability?(capability), "Auto-created permission should have #{capability} capability"
    end
  end

  test "auto-created TrusteeGrant allows all studios" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Test Subagent",
      user_type: "subagent",
      parent_id: @user.id,
    )

    permission = TrusteeGrant.find_by(granting_user: subagent, trusted_user: @user)
    assert permission.present?
    assert permission.allows_studio?(@superagent)
  end
end

