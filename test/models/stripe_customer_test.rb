require "test_helper"

class StripeCustomerTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "stripe-test-#{SecureRandom.hex(4)}")
    @user = create_user(email: "stripe_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @collective = create_collective(tenant: @tenant, created_by: @user, handle: "stripe-col-#{SecureRandom.hex(4)}")
    @collective.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  test "belongs to billable (polymorphic)" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
    )
    assert sc.persisted?
    assert_equal "User", sc.billable_type
    assert_equal @user.id, sc.billable_id
    assert_equal @user, sc.billable
  end

  test "validates uniqueness of billable (type + id)" do
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
    )
    duplicate = StripeCustomer.new(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:billable_id], "has already been taken"
  end

  test "validates uniqueness of stripe_id" do
    stripe_id = "cus_#{SecureRandom.hex(8)}"
    StripeCustomer.create!(
      billable: @user,
      stripe_id: stripe_id,
    )
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    duplicate = StripeCustomer.new(
      billable: other_user,
      stripe_id: stripe_id,
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:stripe_id], "has already been taken"
  end

  test "validates presence of stripe_id" do
    sc = StripeCustomer.new(
      billable: @user,
      stripe_id: nil,
    )
    assert_not sc.valid?
    assert_includes sc.errors[:stripe_id], "can't be blank"
  end

  test "active? returns correct status" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
      active: false,
    )
    assert_not sc.active?

    sc.update!(active: true)
    assert sc.active?
  end

  test "defaults to inactive" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
    )
    assert_not sc.active?
  end

  test "has_many ai_agents returns agents billed to this customer" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
    )
    agent = create_ai_agent(parent: @user, name: "Billed Agent")
    agent.update!(stripe_customer_id: sc.id)

    assert_includes sc.ai_agents, agent
  end

  test "has_many task_runs returns runs billed to this customer" do
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_#{SecureRandom.hex(8)}",
    )
    agent = create_ai_agent(parent: @user, name: "Run Agent")
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: agent,
      initiated_by: @user,
      task: "Test",
      max_steps: 5,
      status: "queued",
      stripe_customer_id: sc.id,
    )

    assert_includes sc.task_runs, task_run
  end
end
