# typed: false

require "test_helper"

class TrioActivatorTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant(subdomain: "trio-activator-#{SecureRandom.hex(4)}")
    @owner = create_user(email: "owner_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@owner)
    @tenant.create_main_collective!(created_by: @owner)
    @collective = T.must(@tenant.main_collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  teardown do
    Tenant.clear_thread_scope
  end

  # === activate! ===

  test "activate! creates a trio user for the collective" do
    TrioActivator.activate!(@collective)

    assert_not_nil @collective.reload.trio_user&.id
    assert_equal "trio", T.must(@collective.trio_user).system_role
  end

  test "activate! seeds default automation rules owned by trio" do
    TrioActivator.activate!(@collective)

    trio = T.must(@collective.reload.trio_user)
    rules = AutomationRule.where(ai_agent_id: trio.id)

    assert rules.exists?, "expected at least one default automation rule"
    assert rules.all? { |r| r.enabled? }, "default rules should be enabled"
    assert rules.all? { |r| r.trigger_type == "event" }, "default rules should be event-triggered"
    assert rules.all? { |r| ["self", "self_or_reply"].include?(r.mention_filter) },
           "default rules should filter on self-mentions (or self+reply)"
  end

  test "activate! seeds rules for note, comment, decision, and commitment events" do
    TrioActivator.activate!(@collective)

    trio = T.must(@collective.reload.trio_user)
    event_types = AutomationRule.where(ai_agent_id: trio.id).flat_map(&:event_types)

    assert_includes event_types, "note.created"
    assert_includes event_types, "comment.created"
    assert_includes event_types, "decision.created"
    assert_includes event_types, "commitment.created"
  end

  test "the mentions-and-replies rule matches both note.created and comment.created events" do
    TrioActivator.activate!(@collective)

    trio = T.must(@collective.reload.trio_user)
    rules = AutomationRule.where(ai_agent_id: trio.id)

    assert rules.for_event_type("note.created").exists?,
           "expected a rule matching note.created"
    assert rules.for_event_type("comment.created").exists?,
           "expected a rule matching comment.created — Trio responds to replies on its comments"
  end

  test "activate! is idempotent when trio is already active" do
    TrioActivator.activate!(@collective)
    trio_a = T.must(@collective.reload.trio_user)
    rule_count_a = AutomationRule.where(ai_agent_id: trio_a.id).count

    TrioActivator.activate!(@collective)
    trio_b = T.must(@collective.reload.trio_user)
    rule_count_b = AutomationRule.where(ai_agent_id: trio_b.id).count

    assert_equal trio_a.id, trio_b.id, "should not create a second trio user"
    assert_equal rule_count_a, rule_count_b, "should not seed extra rules"
  end

  # === deactivate! ===

  test "deactivate! makes collective.trio_user nil" do
    TrioActivator.activate!(@collective)
    assert_not_nil @collective.reload.trio_user&.id

    TrioActivator.deactivate!(@collective)

    assert_nil @collective.reload.trio_user&.id
  end

  test "deactivate! archives the trio's CollectiveMember" do
    TrioActivator.activate!(@collective)
    trio = T.must(@collective.reload.trio_user)
    member = T.must(@collective.collective_members.find_by(user_id: trio.id))
    assert_nil member.archived_at, "precondition: member should be active"

    TrioActivator.deactivate!(@collective)

    assert_not_nil member.reload.archived_at, "expected CollectiveMember to be archived"
  end

  test "deactivate! disables the trio's automation rules" do
    TrioActivator.activate!(@collective)
    trio = T.must(@collective.reload.trio_user)
    rule_ids = AutomationRule.where(ai_agent_id: trio.id).pluck(:id)
    assert rule_ids.any?, "precondition: rules should exist"

    TrioActivator.deactivate!(@collective)

    AutomationRule.where(id: rule_ids).each do |r|
      assert_not r.enabled?, "expected rule #{r.id} to be disabled"
    end
  end

  test "deactivate! is idempotent when trio is already off" do
    assert_nothing_raised do
      TrioActivator.deactivate!(@collective)
    end
    assert_nil @collective.reload.trio_user&.id
  end

  # === reconcile! ===

  test "reconcile! activates when flag is on and trio is inactive" do
    @tenant.enable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", true)
    assert_nil @collective.reload.trio_user&.id, "precondition: trio inactive"

    TrioActivator.reconcile!(@collective)

    assert_not_nil @collective.reload.trio_user&.id
  end

  test "reconcile! deactivates when flag is off and trio is active" do
    TrioActivator.activate!(@collective)
    assert_not_nil @collective.reload.trio_user&.id, "precondition: trio active"
    @tenant.disable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", false)

    TrioActivator.reconcile!(@collective)

    assert_nil @collective.reload.trio_user&.id
  end

  test "activate! sets the explicit trio feature flag to true" do
    TrioActivator.activate!(@collective)

    assert_equal true, @collective.reload.settings.dig("feature_flags", "trio")
  end

  test "deactivate! sets the explicit trio feature flag to false" do
    TrioActivator.activate!(@collective)
    TrioActivator.deactivate!(@collective)

    assert_equal false, @collective.reload.settings.dig("feature_flags", "trio")
  end

  # === activate! after deactivate! (restore) ===

  test "activate! after deactivate! restores the previous trio user" do
    TrioActivator.activate!(@collective)
    original_trio = T.must(@collective.reload.trio_user)

    TrioActivator.deactivate!(@collective)
    TrioActivator.activate!(@collective)

    restored_trio = T.must(@collective.reload.trio_user)
    assert_equal original_trio.id, restored_trio.id, "expected the original trio user to be restored"
  end

  test "activate! after deactivate! re-enables the previous automation rules" do
    TrioActivator.activate!(@collective)
    trio = T.must(@collective.reload.trio_user)
    rule_ids = AutomationRule.where(ai_agent_id: trio.id).pluck(:id)

    TrioActivator.deactivate!(@collective)
    TrioActivator.activate!(@collective)

    AutomationRule.where(id: rule_ids).each do |r|
      assert r.enabled?, "expected rule #{r.id} to be re-enabled"
    end
  end

  test "activate! after deactivate! preserves user-edited rule customizations" do
    TrioActivator.activate!(@collective)
    trio = T.must(@collective.reload.trio_user)
    rule = T.must(AutomationRule.where(ai_agent_id: trio.id).first)
    customized_actions = { "task" => "custom user-edited task" }
    rule.update!(actions: customized_actions, name: "Custom Name")

    TrioActivator.deactivate!(@collective)
    TrioActivator.activate!(@collective)

    rule.reload
    assert_equal customized_actions, rule.actions, "expected user customizations to survive deactivate/activate cycle"
    assert_equal "Custom Name", rule.name
  end

  test "activate! after deactivate! unarchives the trio's CollectiveMember" do
    TrioActivator.activate!(@collective)
    trio = T.must(@collective.reload.trio_user)

    TrioActivator.deactivate!(@collective)
    member = T.must(@collective.collective_members.find_by(user_id: trio.id))
    assert_not_nil member.archived_at, "precondition: member should be archived"

    TrioActivator.activate!(@collective)

    assert_nil member.reload.archived_at, "expected CollectiveMember to be unarchived"
  end

  # === Persona role (mention resolution keys off it) ===

  test "activate! grants the trio persona role" do
    trio = TrioActivator.activate!(@collective)

    member = T.must(@collective.collective_members.find_by(user_id: trio.id))
    assert member.has_role?("trio")
  end

  test "deactivate! removes the trio persona role" do
    trio = TrioActivator.activate!(@collective)
    TrioActivator.deactivate!(@collective)

    member = T.must(@collective.collective_members.find_by(user_id: trio.id))
    assert_not member.has_role?("trio"), "a deactivated trio must drop the persona role"
  end

  test "reactivation restores the trio persona role" do
    trio = TrioActivator.activate!(@collective)
    TrioActivator.deactivate!(@collective)
    TrioActivator.activate!(@collective)

    member = T.must(@collective.collective_members.find_by(user_id: trio.id))
    assert member.has_role?("trio")
  end

  # === Auto-funding from the collective's pool ===

  def open_pool!
    FundingPool.create!(tenant: @tenant, collective: @collective, created_by: @owner, member_draw_cap_cents: 500)
  end

  test "activating trio with an open pool puts it on the pool payroll" do
    pool = open_pool!

    trio = TrioActivator.activate!(@collective)

    assert_equal pool.id, trio.reload.funding_pool_id
  end

  test "reactivating trio reattaches it to the pool" do
    pool = open_pool!
    TrioActivator.activate!(@collective)
    trio = T.must(@collective.reload.trio_user)
    TrioActivator.deactivate!(@collective)
    trio.update!(funding_pool_id: nil)

    TrioActivator.activate!(@collective)

    assert_equal pool.id, trio.reload.funding_pool_id
  end

  test "activating trio without a pool leaves it unfunded" do
    trio = TrioActivator.activate!(@collective)

    assert_nil trio.funding_pool_id
  end

  test "activating trio with a closed pool leaves it unfunded" do
    pool = open_pool!
    pool.archive!

    trio = TrioActivator.activate!(@collective)

    assert_nil trio.reload.funding_pool_id
  end

  test "deactivating trio leaves it attached to the pool" do
    pool = open_pool!
    trio = TrioActivator.activate!(@collective)

    TrioActivator.deactivate!(@collective)

    assert_equal pool.id, trio.reload.funding_pool_id
  end
end
