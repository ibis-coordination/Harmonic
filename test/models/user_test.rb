require "test_helper"

class UserTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "user-test-#{SecureRandom.hex(4)}")
    @user = create_user(email: "usertest_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @studio = create_studio(tenant: @tenant, created_by: @user, handle: "user-studio-#{SecureRandom.hex(4)}")
    @studio.add_user!(@user)
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

  test "user has many studio_users" do
    assert @user.studio_users.any?
    assert_includes @user.studios, @studio
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
    new_studio = Studio.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Invite Studio",
      handle: "invite-studio-#{SecureRandom.hex(4)}"
    )
    invite = StudioInvite.create!(
      tenant: @tenant,
      studio: new_studio,
      created_by: @user,
      invited_user: @user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    assert_not new_studio.user_is_member?(@user)
    @user.accept_invite!(invite)
    assert new_studio.user_is_member?(@user)
  end

  test "user cannot accept invite for another user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    # Add to tenant with unique handle
    TenantUser.create!(tenant: @tenant, user: other_user, handle: "other-user-#{SecureRandom.hex(4)}")

    invite = StudioInvite.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      invited_user: other_user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    assert_raises RuntimeError, "Cannot accept invite for another user" do
      @user.accept_invite!(invite)
    end
  end

  # === Studios Minus Main Tests ===

  test "studios_minus_main excludes main studio" do
    # Set the thread tenant context for the scope
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain) do
      @tenant.create_main_studio!(created_by: @user)
      main_studio = @tenant.main_studio
      main_studio.add_user!(@user)

      studios = @user.studios_minus_main
      assert_not_includes studios, main_studio
      assert_includes studios, @studio
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
end

