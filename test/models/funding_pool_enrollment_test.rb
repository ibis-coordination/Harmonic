# typed: false

require "test_helper"

class FundingPoolEnrollmentTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @pool = FundingPool.create!(collective: @collective, created_by: @user)
    fund!(@user)
  end

  def fund!(user, active: true, pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}")
    StripeCustomer.create!(
      billable: user,
      stripe_id: "cus_#{SecureRandom.hex(6)}",
      active: active,
      pricing_plan_subscription_id: pricing_plan_subscription_id,
    )
  end

  def create_member!(fund: true)
    member = create_user
    @tenant.add_user!(member)
    @collective.add_user!(member)
    fund!(member) if fund
    member
  end

  test "a funded collective member can enroll" do
    enrollment = @pool.enroll!(@user)
    assert enrollment.persisted?
    assert_nil enrollment.archived_at
    assert_equal @tenant.id, enrollment.tenant_id
    assert_equal @collective.id, enrollment.collective_id
  end

  test "an enrollment whose collective does not match the pool's is invalid" do
    other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
    enrollment = FundingPoolEnrollment.new(funding_pool: @pool, user: @user, collective: other_collective)
    assert_not enrollment.valid?
    assert enrollment.errors[:collective].any?
  end

  test "enrollment requires funded billing" do
    member = create_member!(fund: false)
    error = assert_raises(ActiveRecord::RecordInvalid) { @pool.enroll!(member) }
    assert_match(/billing/i, error.message)
  end

  test "an inactive billing customer does not satisfy the enrollment gate" do
    member = create_member!(fund: false)
    fund!(member, active: false)
    assert_raises(ActiveRecord::RecordInvalid) { @pool.enroll!(member) }
  end

  test "enrollment requires active membership in the pool's collective" do
    outsider = create_user
    @tenant.add_user!(outsider)
    fund!(outsider)
    error = assert_raises(ActiveRecord::RecordInvalid) { @pool.enroll!(outsider) }
    assert_match(/member/i, error.message)
  end

  test "an archived membership does not satisfy the enrollment gate" do
    member = create_member!
    @collective.collective_members.find_by!(user: member).archive!
    assert_raises(ActiveRecord::RecordInvalid) { @pool.enroll!(member) }
  end

  test "AI agents cannot enroll" do
    agent = create_ai_agent(parent: @user)
    @collective.add_user!(agent)
    fund!(agent)
    error = assert_raises(ActiveRecord::RecordInvalid) { @pool.enroll!(agent) }
    assert_match(/human/i, error.message)
  end

  test "enrolling in a closed pool is refused" do
    member = create_member!
    @pool.archive!
    assert_raises(ActiveRecord::RecordInvalid) { @pool.enroll!(member) }
  end

  test "withdraw! archives the enrollment and enroll! reactivates it" do
    enrollment = @pool.enroll!(@user)
    enrollment.withdraw!
    assert enrollment.reload.archived?

    reactivated = @pool.enroll!(@user)
    assert_equal enrollment.id, reactivated.id
    assert_not reactivated.archived?
  end

  test "re-enrollment re-checks the gate" do
    member = create_member!
    enrollment = @pool.enroll!(member)
    enrollment.withdraw!
    member.stripe_customer.update!(active: false)
    assert_raises(ActiveRecord::RecordInvalid) { @pool.enroll!(member) }
    assert enrollment.reload.archived?
  end

  test "a user can enroll in only one row per pool" do
    @pool.enroll!(@user)
    duplicate = FundingPoolEnrollment.new(funding_pool: @pool, user: @user)
    assert_not duplicate.valid?
  end

  test "active scope excludes withdrawn enrollments" do
    member = create_member!
    @pool.enroll!(@user)
    @pool.enroll!(member).withdraw!
    assert_equal [@user.id], @pool.enrollments.active.pluck(:user_id)
  end
end
