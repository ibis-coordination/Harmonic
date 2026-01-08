require "test_helper"

class UserAuthorizationTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "auth-test-#{SecureRandom.hex(4)}")
    @user = create_unique_user
    @tenant.add_user!(@user)
    @studio = create_studio(tenant: @tenant, created_by: @user, handle: "auth-studio-#{SecureRandom.hex(4)}")
    @studio.add_user!(@user)
  end

  # Helper to create users with unique names to avoid handle collisions
  def create_unique_user(email: nil, name: nil)
    suffix = SecureRandom.hex(4)
    User.create!(
      email: email || "user_#{suffix}@example.com",
      name: name || "User #{suffix}",
      user_type: "person"
    )
  end

  # === User Type Tests ===

  test "person user type is valid" do
    user = User.new(email: "person@example.com", name: "Person", user_type: "person")
    assert user.valid?
    assert user.person?
    assert_not user.simulated?
    assert_not user.trustee?
  end

  test "simulated user type requires parent_id" do
    user = User.new(email: "simulated@example.com", name: "Simulated", user_type: "simulated")
    assert_not user.valid?
    assert_includes user.errors[:parent_id], "must be set for simulated users"
  end

  test "simulated user with parent is valid" do
    parent = create_user
    user = User.new(
      email: "simulated@example.com",
      name: "Simulated",
      user_type: "simulated",
      parent_id: parent.id
    )
    assert user.valid?
    assert user.simulated?
  end

  test "non-simulated user cannot have parent_id" do
    parent = create_user
    user = User.new(
      email: "person@example.com",
      name: "Person",
      user_type: "person",
      parent_id: parent.id
    )
    assert_not user.valid?
    assert_includes user.errors[:parent_id], "can only be set for simulated users"
  end

  test "user cannot be its own parent" do
    user = create_user
    user.user_type = "simulated"
    user.parent_id = user.id
    assert_not user.valid?
    assert_includes user.errors[:parent_id], "user cannot be its own parent"
  end

  test "trustee user type is valid" do
    user = User.new(email: "trustee@example.com", name: "Trustee", user_type: "trustee")
    assert user.valid?
    assert user.trustee?
  end

  test "invalid user type is rejected" do
    user = User.new(email: "invalid@example.com", name: "Invalid", user_type: "invalid")
    assert_not user.valid?
    assert_includes user.errors[:user_type], "is not included in the list"
  end

  # === Impersonation Tests ===

  test "parent can impersonate their simulated user" do
    parent = create_unique_user
    @tenant.add_user!(parent)

    simulated = User.create!(
      email: "sim_#{SecureRandom.hex(4)}@example.com",
      name: "Simulated #{SecureRandom.hex(4)}",
      user_type: "simulated",
      parent_id: parent.id
    )
    @tenant.add_user!(simulated)

    # Set tenant context for archived? check
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    assert parent.can_impersonate?(simulated)
  end

  test "user cannot impersonate non-child simulated user" do
    parent1 = create_unique_user
    parent2 = create_unique_user
    @tenant.add_user!(parent1)
    @tenant.add_user!(parent2)

    simulated = User.create!(
      email: "sim_#{SecureRandom.hex(4)}@example.com",
      name: "Simulated #{SecureRandom.hex(4)}",
      user_type: "simulated",
      parent_id: parent1.id
    )
    @tenant.add_user!(simulated)

    # Set tenant context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    assert_not parent2.can_impersonate?(simulated)
  end

  test "user cannot impersonate archived simulated user" do
    parent = create_unique_user
    @tenant.add_user!(parent)
    simulated = User.create!(
      email: "sim_#{SecureRandom.hex(4)}@example.com",
      name: "Simulated #{SecureRandom.hex(4)}",
      user_type: "simulated",
      parent_id: parent.id
    )

    # Add to tenant so we can archive
    @tenant.add_user!(simulated)

    # Set tenant context for archived? check
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    simulated.tenant_user.update!(archived_at: Time.current)

    assert_not parent.can_impersonate?(simulated)
  end

  test "user cannot impersonate regular person user" do
    user1 = create_unique_user
    user2 = create_unique_user
    @tenant.add_user!(user1)
    @tenant.add_user!(user2)

    # Set tenant context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    assert_not user1.can_impersonate?(user2)
  end

  # === Edit Permission Tests ===

  test "user can edit themselves" do
    assert @user.can_edit?(@user)
  end

  test "user cannot edit other users" do
    other_user = create_user
    assert_not @user.can_edit?(other_user)
  end

  test "parent can edit their simulated user" do
    simulated = User.create!(
      email: "sim_#{SecureRandom.hex(4)}@example.com",
      name: "Simulated User",
      user_type: "simulated",
      parent_id: @user.id
    )

    assert @user.can_edit?(simulated)
  end

  # === Tenant Access Tests ===

  test "user has access to tenant they belong to" do
    tu = @tenant.tenant_users.find_by(user: @user)
    assert_not_nil tu
    assert_not tu.archived?
  end

  test "user tenant_user returns correct association" do
    # Set the current tenant context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    tu = @user.tenant_user
    assert_not_nil tu
    assert_equal @tenant.id, tu.tenant_id
    assert_equal @user.id, tu.user_id
  end

  # === Studio Access Tests ===

  test "user has access to studio they belong to" do
    su = @studio.studio_users.find_by(user: @user)
    assert_not_nil su
  end

  test "user does not have access to studio they don't belong to" do
    # Create another studio in the same tenant
    other_studio = Studio.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Other Studio",
      handle: "other-studio-#{SecureRandom.hex(4)}"
    )

    # Create a new user not in other_studio
    new_user = create_user(email: "new_user_#{SecureRandom.hex(4)}@example.com")
    tu = TenantUser.create!(
      tenant: @tenant,
      user: new_user,
      display_name: new_user.name,
      handle: "new-user-#{SecureRandom.hex(4)}"
    )
    # Don't add new_user to other_studio

    su = other_studio.studio_users.find_by(user: new_user)
    assert_nil su
  end

  # === Archive Tests ===

  test "archiving user archives their tenant_user" do
    user = create_user(email: "archive_user_#{SecureRandom.hex(4)}@example.com")
    TenantUser.create!(
      tenant: @tenant,
      user: user,
      display_name: user.name,
      handle: "archive-user-#{SecureRandom.hex(4)}"
    )

    # Set tenant context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    assert_not user.archived?

    user.archive!

    assert user.archived?
    assert_not_nil user.archived_at
  end

  test "unarchiving user unarchives their tenant_user" do
    user = create_user(email: "unarchive_user_#{SecureRandom.hex(4)}@example.com")
    TenantUser.create!(
      tenant: @tenant,
      user: user,
      display_name: user.name,
      handle: "unarchive-user-#{SecureRandom.hex(4)}"
    )

    # Set tenant context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    user.archive!
    assert user.archived?

    user.unarchive!
    assert_not user.archived?
  end
end
