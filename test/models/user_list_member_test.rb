require "test_helper"

class UserListMemberTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @other = make_user
    @list = UserList.create!(creator: @user, owner: @user, name: "Design")
  end

  def make_user(suffix = SecureRandom.hex(4))
    u = create_user(email: "u-#{suffix}@example.com", name: "U #{suffix}")
    @tenant.add_user!(u)
    @collective.add_user!(u)
    u
  end

  # ---- Creation ----

  test "create with required fields succeeds" do
    m = UserListMember.create!(user_list: @list, user: @other, added_by: @user)
    assert m.persisted?
    assert_equal @list, m.user_list
    assert_equal @other, m.user
    assert_equal @user, m.added_by
    assert_equal @tenant.id, m.tenant_id
    assert_equal @collective.id, m.collective_id
  end

  test "added_by required" do
    m = UserListMember.new(user_list: @list, user: @other)
    assert_not m.valid?
  end

  # ---- Uniqueness ----

  test "same user cannot be added to the same list twice" do
    UserListMember.create!(user_list: @list, user: @other, added_by: @user)
    dup = UserListMember.new(user_list: @list, user: @other, added_by: @user)
    assert_not dup.valid?
    assert_includes dup.errors[:user_id], "has already been taken"
  end

  test "same user can be on two different lists" do
    other_list = UserList.create!(creator: @user, owner: @user, name: "Other")
    UserListMember.create!(user_list: @list, user: @other, added_by: @user)
    second = UserListMember.create!(user_list: other_list, user: @other, added_by: @user)
    assert second.persisted?
  end

  # ---- Block symmetry ----

  test "blocked user cannot be added (owner blocked member)" do
    UserBlock.create!(blocker: @user, blocked: @other, tenant: @tenant)
    m = UserListMember.new(user_list: @list, user: @other, added_by: @user)
    assert_not m.valid?
    assert_includes m.errors[:user_id].join(" "), "block"
  end

  test "blocked user cannot be added (member blocked owner)" do
    UserBlock.create!(blocker: @other, blocked: @user, tenant: @tenant)
    m = UserListMember.new(user_list: @list, user: @other, added_by: @user)
    assert_not m.valid?
    assert_includes m.errors[:user_id].join(" "), "block"
  end

  test "blocked-adder relationship also prevents addition" do
    third = make_user
    UserBlock.create!(blocker: third, blocked: @other, tenant: @tenant)
    m = UserListMember.new(user_list: @list, user: @other, added_by: third)
    assert_not m.valid?
    assert_includes m.errors[:user_id].join(" "), "block"
  end

  # ---- Collective membership requirement ----

  test "non-collective-member cannot be added" do
    stranger = create_user(email: "s-#{SecureRandom.hex(4)}@example.com", name: "S #{SecureRandom.hex(4)}")
    @tenant.add_user!(stranger)
    m = UserListMember.new(user_list: @list, user: stranger, added_by: @user)
    assert_not m.valid?
    assert_includes m.errors[:user_id].join(" "), "collective"
  end

  # ---- Scope-mismatch guard ----

  test "scope_matches_list rejects mismatched collective_id" do
    other_collective = create_collective(tenant: @tenant, created_by: @user, name: "Other", handle: "o-#{SecureRandom.hex(4)}")
    m = UserListMember.new(user_list: @list, user: @other, added_by: @user, collective_id: other_collective.id)
    assert_not m.valid?
    assert_includes m.errors[:collective_id].join(" "), "user_list"
  end

  test "scope_matches_list rejects mismatched tenant_id" do
    other_tenant = create_tenant(subdomain: "o-#{SecureRandom.hex(4)}")
    m = UserListMember.new(user_list: @list, user: @other, added_by: @user, tenant_id: other_tenant.id)
    assert_not m.valid?
    assert_includes m.errors[:tenant_id].join(" "), "user_list"
  end

  # ---- attr_readonly ----

  test "user_list_id is immutable" do
    m = UserListMember.create!(user_list: @list, user: @other, added_by: @user)
    other_list = UserList.create!(creator: @user, owner: @user, name: "Other")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { m.update!(user_list_id: other_list.id) }
  end

  # ---- Association cleanup ----

  test "destroying the list destroys its members" do
    UserListMember.create!(user_list: @list, user: @other, added_by: @user)
    @list.destroy!
    assert_equal 0, UserListMember.where(user_list_id: @list.id).count
  end

  # ---- User.lists_im_on ----

  test "user.lists_im_on returns lists the user is a member of" do
    UserListMember.create!(user_list: @list, user: @other, added_by: @user)
    assert_includes @other.lists_im_on, @list
  end

  # ---- Tenant isolation ----

  test "tenant scoping isolates memberships" do
    UserListMember.create!(user_list: @list, user: @other, added_by: @user)
    other_tenant = create_tenant(subdomain: "ot-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    Collective.clear_thread_scope
    assert_equal 0, UserListMember.unscope(where: :collective_id).count
  end
end
