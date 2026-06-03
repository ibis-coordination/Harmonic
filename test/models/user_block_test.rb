require "test_helper"

class UserBlockTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)
  end

  test "UserBlock.create works" do
    block = UserBlock.create!(
      blocker: @user,
      blocked: @other_user,
      tenant: @tenant,
    )

    assert block.persisted?
    assert_equal @user, block.blocker
    assert_equal @other_user, block.blocked
    assert_equal @tenant.id, block.tenant_id
  end

  test "cannot block yourself" do
    block = UserBlock.new(
      blocker: @user,
      blocked: @user,
      tenant: @tenant,
    )

    assert_not block.valid?
    assert_includes block.errors[:blocked_id], "cannot block yourself"
  end

  test "duplicate block is rejected" do
    UserBlock.create!(
      blocker: @user,
      blocked: @other_user,
      tenant: @tenant,
    )

    duplicate = UserBlock.new(
      blocker: @user,
      blocked: @other_user,
      tenant: @tenant,
    )

    assert_not duplicate.valid?
  end

  test "reason is optional" do
    block = UserBlock.create!(
      blocker: @user,
      blocked: @other_user,
      tenant: @tenant,
      reason: "Spamming comments",
    )

    assert_equal "Spamming comments", block.reason
  end

  test "UserBlock.between? returns true when either user has blocked the other" do
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    assert UserBlock.between?(@user, @other_user)
    assert UserBlock.between?(@other_user, @user)
  end

  test "UserBlock.between? returns false when no block exists" do
    assert_not UserBlock.between?(@user, @other_user)
  end

  test "user blocked? helper" do
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    assert @user.blocked?(@other_user)
    assert_not @other_user.blocked?(@user)
  end

  test "user blocked_by? helper" do
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    assert @other_user.blocked_by?(@user)
    assert_not @user.blocked_by?(@other_user)
  end

  test "cannot block your own AI agent" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)

    block = UserBlock.new(blocker: @user, blocked: agent, tenant: @tenant)
    assert_not block.valid?
    assert_includes block.errors[:blocked_id], "cannot block your own agent"
  end

  test "agent cannot block their parent user" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)

    block = UserBlock.new(blocker: agent, blocked: @user, tenant: @tenant)
    assert_not block.valid?
    assert_includes block.errors[:blocker_id], "agents cannot block their parent user"
  end

  test "tenant scoping isolates blocks" do
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)

    assert_equal 0, UserBlock.count
  end

  # === Primary-list cleanup on block ===

  test "blocking removes both users from each other's primary lists when mutually tuned in" do
    a_list = @user.primary_user_list_in!(@tenant)
    b_list = @other_user.primary_user_list_in!(@tenant)
    a_list.user_list_members.create!(added_by: @user, user: @other_user)
    b_list.user_list_members.create!(added_by: @other_user, user: @user)

    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    assert_not a_list.user_list_members.exists?(user_id: @other_user.id),
               "expected @other_user to be removed from @user's primary list"
    assert_not b_list.user_list_members.exists?(user_id: @user.id),
               "expected @user to be removed from @other_user's primary list"
  end

  test "blocking removes only the existing direction when tune-in is one-sided" do
    a_list = @user.primary_user_list_in!(@tenant)
    a_list.user_list_members.create!(added_by: @user, user: @other_user)
    # @other_user has no primary list / no membership of @user.

    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    assert_not a_list.user_list_members.exists?(user_id: @other_user.id)
  end

  test "blocking succeeds when neither user has a primary list" do
    assert_nothing_raised do
      UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)
    end
  end
end
