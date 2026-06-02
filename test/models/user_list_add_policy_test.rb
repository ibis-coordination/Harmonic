require "test_helper"

# Tests for UserList#can_add?(actor:, target:) and the add_policy enum.
# The matrix:
#                    | owner adds | members add others | non-member adds others | non-member adds self
#   ---              | ----       | ----               | ----                   | ----
#   owner_only       | yes        | no                 | no                     | no
#   self_add         | yes        | no                 | no                     | yes
#   members_add      | yes        | yes                | no                     | no
#   anyone_add       | yes        | yes                | yes                    | yes
class UserListAddPolicyTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @owner = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def make_collective_user(suffix = SecureRandom.hex(4))
    user = create_user(email: "u-#{suffix}@example.com", name: "U #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def list_with(add_policy:)
    UserList.create!(creator: @owner, owner: @owner, name: "L #{add_policy}", add_policy: add_policy)
  end

  test "valid add_policy values" do
    assert_equal %w[owner_only self_add members_add anyone_add].sort, UserList::VALID_ADD_POLICIES.sort
  end

  test "add_policy column defaults to owner_only" do
    list = UserList.create!(creator: @owner, owner: @owner, name: "Default")
    assert_equal "owner_only", list.add_policy
  end

  test "add_policy validation rejects unknown values" do
    list = UserList.new(creator: @owner, owner: @owner, name: "X", add_policy: "wild_west")
    assert_not list.valid?
  end

  # ---- owner_only ----

  test "owner_only: owner can add anyone" do
    list = list_with(add_policy: "owner_only")
    other = make_collective_user
    assert list.can_add?(actor: @owner, target: other)
    assert list.can_add?(actor: @owner, target: @owner)
  end

  test "owner_only: a list member cannot add others" do
    list = list_with(add_policy: "owner_only")
    member = make_collective_user
    list.user_list_members.create!(added_by: @owner, user: member)
    other = make_collective_user
    assert_not list.can_add?(actor: member, target: other)
  end

  test "owner_only: a non-member cannot self-add" do
    list = list_with(add_policy: "owner_only")
    stranger = make_collective_user
    assert_not list.can_add?(actor: stranger, target: stranger)
  end

  # ---- self_add ----

  test "self_add: anyone in the collective can add themselves" do
    list = list_with(add_policy: "self_add")
    user = make_collective_user
    assert list.can_add?(actor: user, target: user)
  end

  test "self_add: a member cannot add others" do
    list = list_with(add_policy: "self_add")
    member = make_collective_user
    list.user_list_members.create!(added_by: @owner, user: member)
    other = make_collective_user
    assert_not list.can_add?(actor: member, target: other)
  end

  test "self_add: a non-member cannot add others" do
    list = list_with(add_policy: "self_add")
    actor = make_collective_user
    target = make_collective_user
    assert_not list.can_add?(actor: actor, target: target)
  end

  test "self_add: owner can still add anyone" do
    list = list_with(add_policy: "self_add")
    other = make_collective_user
    assert list.can_add?(actor: @owner, target: other)
  end

  # ---- members_add ----

  test "members_add: a member can add others" do
    list = list_with(add_policy: "members_add")
    member = make_collective_user
    list.user_list_members.create!(added_by: @owner, user: member)
    other = make_collective_user
    assert list.can_add?(actor: member, target: other)
  end

  test "members_add: a non-member cannot add others" do
    list = list_with(add_policy: "members_add")
    actor = make_collective_user
    target = make_collective_user
    assert_not list.can_add?(actor: actor, target: target)
  end

  test "members_add: a non-member cannot self-add" do
    list = list_with(add_policy: "members_add")
    stranger = make_collective_user
    assert_not list.can_add?(actor: stranger, target: stranger)
  end

  test "members_add: owner can add anyone" do
    list = list_with(add_policy: "members_add")
    other = make_collective_user
    assert list.can_add?(actor: @owner, target: other)
  end

  # ---- anyone_add ----

  test "anyone_add: any collective member can add anyone" do
    list = list_with(add_policy: "anyone_add")
    actor = make_collective_user
    target = make_collective_user
    assert list.can_add?(actor: actor, target: target)
    assert list.can_add?(actor: actor, target: actor)
  end

  # ---- common rules: actor must be authenticated; nil actor → false ----

  test "nil actor cannot add anyone, regardless of policy" do
    UserList::VALID_ADD_POLICIES.each do |policy|
      list = list_with(add_policy: policy)
      target = make_collective_user
      assert_not list.can_add?(actor: nil, target: target), "policy #{policy} should reject nil actor"
    end
  end

  # ---- primary lists must be owner_only ----

  test "a primary list cannot be created with a non-owner_only add_policy" do
    %w[self_add members_add anyone_add].each do |policy|
      list = UserList.new(creator: @owner, owner: @owner, name: "P #{policy}",
                          is_primary: true, add_policy: policy)
      assert_not list.valid?, "primary + #{policy} should be invalid"
      assert_includes list.errors[:add_policy].join(" "), "primary"
    end
  end

  test "an existing primary list cannot be updated to a non-owner_only add_policy" do
    list = UserList.create!(creator: @owner, owner: @owner, name: "Mine",
                            is_primary: true, add_policy: "owner_only")
    list.add_policy = "self_add"
    assert_not list.valid?
    assert_includes list.errors[:add_policy].join(" "), "primary"
  end

  test "primary_user_list_in! creates the primary with owner_only" do
    tenant = create_tenant(subdomain: "pl-#{SecureRandom.hex(4)}")
    user = create_user(email: "pl-#{SecureRandom.hex(4)}@example.com", name: "PL #{SecureRandom.hex(4)}")
    tenant.add_user!(user)
    tenant.create_main_collective!(created_by: user)
    list = user.primary_user_list_in!(tenant)
    assert_equal "owner_only", list.add_policy
  end

  # ---- private lists must be owner_only ----

  test "a private list cannot be created with a non-owner_only add_policy" do
    %w[self_add members_add anyone_add].each do |policy|
      list = UserList.new(creator: @owner, owner: @owner, name: "Priv #{policy}",
                          visibility: "private", add_policy: policy)
      assert_not list.valid?, "private + #{policy} should be invalid"
      assert_includes list.errors[:add_policy].join(" "), "private"
    end
  end

  test "switching a public list to private requires add_policy to be owner_only" do
    list = UserList.create!(creator: @owner, owner: @owner, name: "Pub", add_policy: "anyone_add")
    list.visibility = "private"
    assert_not list.valid?
    assert_includes list.errors[:add_policy].join(" "), "private"
  end

  test "switching a public list to private + owner_only together succeeds" do
    list = UserList.create!(creator: @owner, owner: @owner, name: "Pub", add_policy: "anyone_add")
    assert list.update(visibility: "private", add_policy: "owner_only")
  end

  # ---- DB CHECK constraint (defense in depth) ----

  test "the DB CHECK constraint rejects a primary list with non-owner_only policy" do
    list = UserList.new(creator: @owner, owner: @owner, name: "X",
                        is_primary: true, add_policy: "anyone_add")
    assert_raises(ActiveRecord::StatementInvalid) { list.save(validate: false) }
  end

  test "the DB CHECK constraint rejects a private list with non-owner_only policy" do
    list = UserList.new(creator: @owner, owner: @owner, name: "X",
                        visibility: "private", add_policy: "anyone_add")
    assert_raises(ActiveRecord::StatementInvalid) { list.save(validate: false) }
  end
end
