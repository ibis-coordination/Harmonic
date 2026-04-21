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

  test "tenant scoping isolates blocks" do
    UserBlock.create!(blocker: @user, blocked: @other_user, tenant: @tenant)

    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)

    assert_equal 0, UserBlock.count
  end
end
