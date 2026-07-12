# typed: false

require "test_helper"

class FundingPoolTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def create_pool!(collective: @collective, **overrides)
    FundingPool.create!(collective: collective, created_by: @user, member_draw_cap_cents: 500, **overrides)
  end

  test "a standard collective can have a funding pool" do
    pool = create_pool!
    assert_equal @collective.id, pool.collective_id
    assert_equal @tenant.id, pool.tenant_id
    assert_equal pool, @collective.reload.funding_pool
  end

  test "a collective can have only one funding pool" do
    create_pool!
    pool = FundingPool.new(collective: @collective, created_by: @user)
    assert_not pool.valid?
    assert pool.errors[:collective_id].any?
  end

  test "non-standard collectives cannot have funding pools" do
    workspace = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Workspace",
      handle: "ws-#{SecureRandom.hex(4)}",
      collective_type: "private_workspace",
    )
    pool = FundingPool.new(collective: workspace, created_by: @user)
    assert_not pool.valid?
    assert pool.errors[:collective_id].any?
  end

  test "the draw ceiling is mandatory and must be a positive integer" do
    pool = create_pool!
    pool.member_draw_cap_cents = 0
    assert_not pool.valid?
    pool.member_draw_cap_cents = 500
    assert pool.valid?
    pool.member_draw_cap_cents = nil
    assert_not pool.valid?, "a pool must always carry an explicit draw ceiling"
  end

  test "the draw cap period must be day, week, or month" do
    pool = create_pool!
    FundingPool::DRAW_CAP_PERIODS.each do |period|
      pool.member_draw_cap_period = period
      assert pool.valid?, "#{period} should be a valid period"
    end
    pool.member_draw_cap_period = "fortnight"
    assert_not pool.valid?
  end

  test "destroying a pool detaches its agents instead of orphaning them" do
    pool = create_pool!
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(6)}",
      active: true,
      pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}",
    )
    pool.enroll!(@user, draw_cap_cents: 500)
    agent = create_ai_agent(parent: @user)
    agent.update!(funding_pool: pool)

    # Collective deletion destroys the pool through has_one dependent: :destroy;
    # an attached agent must not turn that into a foreign-key violation.
    pool.destroy!
    assert_nil agent.reload.funding_pool_id
  end

  test "archive! closes the pool and unarchive! reopens it" do
    pool = create_pool!
    assert_not pool.archived?
    pool.archive!
    assert pool.archived?
    pool.unarchive!
    assert_not pool.archived?
  end
end
