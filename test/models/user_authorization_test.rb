require "test_helper"

class UserAuthorizationTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "auth-test-#{SecureRandom.hex(4)}")
    @user = create_unique_user
    @tenant.add_user!(@user)
    @superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "auth-studio-#{SecureRandom.hex(4)}")
    @superagent.add_user!(@user)
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
    assert_not user.subagent?
    assert_not user.trustee?
  end

  test "subagent user type requires parent_id" do
    user = User.new(email: "subagent@example.com", name: "Subagent", user_type: "subagent")
    assert_not user.valid?
    assert_includes user.errors[:parent_id], "must be set for subagent users"
  end

  test "subagent user with parent is valid" do
    parent = create_user
    user = User.new(
      email: "subagent@example.com",
      name: "Subagent",
      user_type: "subagent",
      parent_id: parent.id
    )
    assert user.valid?
    assert user.subagent?
  end

  test "non-subagent user cannot have parent_id" do
    parent = create_user
    user = User.new(
      email: "person@example.com",
      name: "Person",
      user_type: "person",
      parent_id: parent.id
    )
    assert_not user.valid?
    assert_includes user.errors[:parent_id], "can only be set for subagent users"
  end

  test "user cannot be its own parent" do
    user = create_user
    user.user_type = "subagent"
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

  test "parent can impersonate their subagent user" do
    parent = create_unique_user
    @tenant.add_user!(parent)

    subagent = create_subagent(parent: parent, name: "Subagent #{SecureRandom.hex(4)}")
    @tenant.add_user!(subagent)

    # Set tenant context for archived? check
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    assert parent.can_impersonate?(subagent)
  end

  test "user cannot impersonate non-child subagent user" do
    parent1 = create_unique_user
    parent2 = create_unique_user
    @tenant.add_user!(parent1)
    @tenant.add_user!(parent2)

    subagent = create_subagent(parent: parent1, name: "Subagent #{SecureRandom.hex(4)}")
    @tenant.add_user!(subagent)

    # Set tenant context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    assert_not parent2.can_impersonate?(subagent)
  end

  test "user cannot impersonate archived subagent user" do
    parent = create_unique_user
    @tenant.add_user!(parent)
    subagent = create_subagent(parent: parent, name: "Subagent #{SecureRandom.hex(4)}")

    # Add to tenant so we can archive
    @tenant.add_user!(subagent)

    # Set tenant context for archived? check
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    subagent.tenant_user.update!(archived_at: Time.current)

    assert_not parent.can_impersonate?(subagent)
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

  test "parent can edit their subagent user" do
    subagent = create_subagent(parent: @user, name: "Subagent User")

    assert @user.can_edit?(subagent)
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
    su = @superagent.superagent_members.find_by(user: @user)
    assert_not_nil su
  end

  test "user does not have access to studio they don't belong to" do
    # Create another studio in the same tenant
    other_superagent = Superagent.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Other Studio",
      handle: "other-studio-#{SecureRandom.hex(4)}"
    )

    # Create a new user not in other_superagent
    new_user = create_user(email: "new_user_#{SecureRandom.hex(4)}@example.com")
    tu = TenantUser.create!(
      tenant: @tenant,
      user: new_user,
      display_name: new_user.name,
      handle: "new-user-#{SecureRandom.hex(4)}"
    )
    # Don't add new_user to other_superagent

    su = other_superagent.superagent_members.find_by(user: new_user)
    assert_nil su
  end

  # === Add Subagent to Studio Tests ===

  test "parent can add subagent to studio where they have invite permission" do
    parent = create_unique_user
    @tenant.add_user!(parent)
    @superagent.add_user!(parent, roles: ['admin'])

    subagent = create_subagent(parent: parent, name: "Subagent #{SecureRandom.hex(4)}")
    @tenant.add_user!(subagent)

    assert parent.can_add_subagent_to_superagent?(subagent, @superagent)
  end

  test "parent cannot add subagent to studio where they lack invite permission" do
    parent = create_unique_user
    @tenant.add_user!(parent)
    # Parent is not a member of the studio

    subagent = create_subagent(parent: parent, name: "Subagent #{SecureRandom.hex(4)}")
    @tenant.add_user!(subagent)

    assert_not parent.can_add_subagent_to_superagent?(subagent, @superagent)
  end

  test "user cannot add another user's subagent to studio" do
    parent1 = create_unique_user
    parent2 = create_unique_user
    @tenant.add_user!(parent1)
    @tenant.add_user!(parent2)
    @superagent.add_user!(parent2, roles: ['admin'])

    subagent = create_subagent(parent: parent1, name: "Subagent #{SecureRandom.hex(4)}")
    @tenant.add_user!(subagent)

    # Parent2 has invite permission but subagent belongs to parent1
    assert_not parent2.can_add_subagent_to_superagent?(subagent, @superagent)
  end

  test "cannot add non-subagent user to studio via can_add_subagent_to_studio" do
    parent = create_unique_user
    regular_user = create_unique_user
    @tenant.add_user!(parent)
    @tenant.add_user!(regular_user)
    @superagent.add_user!(parent, roles: ['admin'])

    assert_not parent.can_add_subagent_to_superagent?(regular_user, @superagent)
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
