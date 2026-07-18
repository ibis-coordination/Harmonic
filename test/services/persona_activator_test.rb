# typed: false

require "test_helper"

class PersonaActivatorTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant(subdomain: "persona-activator-#{SecureRandom.hex(4)}")
    @owner = create_user(email: "owner_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@owner)
    @tenant.create_main_collective!(created_by: @owner)
    @collective = T.must(@tenant.main_collective)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  teardown do
    Tenant.clear_thread_scope
  end

  def cadence_user
    @collective.reload.persona_user("cadence")
  end

  # === activate! ===

  test "activate! creates all three persona users for the collective" do
    PersonaActivator.activate!(@collective)

    assert_equal ["melody", "counterpoint", "cadence"],
                 @collective.reload.persona_users.map(&:system_role)
  end

  test "activate! in a private workspace creates the full ensemble too" do
    workspace = T.must(@owner.private_workspace)

    PersonaActivator.activate!(workspace)

    assert_equal ["melody", "counterpoint", "cadence"],
                 workspace.reload.persona_users.map(&:system_role)
  end

  test "activate! seeds default automation rules owned by each persona" do
    PersonaActivator.activate!(@collective)

    @collective.reload.persona_users.each do |agent|
      rules = AutomationRule.where(ai_agent_id: agent.id)

      assert rules.exists?, "expected default automation rules for #{agent.system_role}"
      assert rules.all?(&:enabled?), "default rules should be enabled"
      assert(rules.all? { |r| r.trigger_type == "event" }, "default rules should be event-triggered")
      assert(rules.all? { |r| ["self", "self_or_reply"].include?(r.mention_filter) },
             "default rules should filter on self-mentions (or self+reply)")
    end
  end

  test "every persona seeds the same mention responder — no persona is special" do
    PersonaActivator.activate!(@collective)

    @collective.reload.persona_users.each do |agent|
      rules = AutomationRule.where(ai_agent_id: agent.id)
      assert_equal 1, rules.count, "#{agent.system_role} should ship exactly the mention responder"
      assert rules.for_event_type("note.created").exists?,
             "expected #{agent.system_role} to respond to note.created"
      assert rules.for_event_type("comment.created").exists?,
             "expected #{agent.system_role} to respond to comment.created"
    end
  end

  test "activate! is idempotent when the ensemble is already active" do
    PersonaActivator.activate!(@collective)
    ids_a = @collective.reload.persona_users.map(&:id).sort
    rule_count_a = AutomationRule.where(ai_agent_id: ids_a).count

    PersonaActivator.activate!(@collective)
    ids_b = @collective.reload.persona_users.map(&:id).sort
    rule_count_b = AutomationRule.where(ai_agent_id: ids_b).count

    assert_equal ids_a, ids_b, "should not create second persona users"
    assert_equal rule_count_a, rule_count_b, "should not seed extra rules"
  end

  # === deactivate! ===

  test "deactivate! empties persona_users" do
    PersonaActivator.activate!(@collective)
    assert_equal 3, @collective.reload.persona_users.size

    PersonaActivator.deactivate!(@collective)

    assert_empty @collective.reload.persona_users
  end

  test "deactivate! archives each persona's CollectiveMember" do
    PersonaActivator.activate!(@collective)
    agent_ids = @collective.reload.persona_users.map(&:id)

    PersonaActivator.deactivate!(@collective)

    @collective.collective_members.where(user_id: agent_ids).each do |member|
      assert_not_nil member.archived_at, "expected CollectiveMember to be archived"
    end
  end

  test "deactivate! disables the personas' automation rules" do
    PersonaActivator.activate!(@collective)
    agent_ids = @collective.reload.persona_users.map(&:id)
    rule_ids = AutomationRule.where(ai_agent_id: agent_ids).pluck(:id)
    assert rule_ids.any?, "precondition: rules should exist"

    PersonaActivator.deactivate!(@collective)

    AutomationRule.where(id: rule_ids).each do |r|
      assert_not r.enabled?, "expected rule #{r.id} to be disabled"
    end
  end

  test "deactivate! is idempotent when the ensemble is already off" do
    assert_nothing_raised do
      PersonaActivator.deactivate!(@collective)
    end
    assert_empty @collective.reload.persona_users
  end

  # === reconcile! ===

  test "reconcile! activates the ensemble when the trio flag is on" do
    @tenant.enable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", true)
    assert_empty @collective.reload.persona_users, "precondition: ensemble inactive"

    PersonaActivator.reconcile!(@collective)

    assert_equal 3, @collective.reload.persona_users.size
  end

  test "reconcile! deactivates when the flag is off and personas are active" do
    PersonaActivator.activate!(@collective)
    assert_equal 3, @collective.reload.persona_users.size, "precondition: ensemble active"
    @tenant.disable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", false)

    PersonaActivator.reconcile!(@collective)

    assert_empty @collective.reload.persona_users
  end

  test "reconcile! heals a partial ensemble — a missing persona activates" do
    @tenant.enable_feature_flag!("trio")
    @collective.set_feature_flag!("trio", true)
    PersonaActivator.reconcile!(@collective)
    # Simulate a collective enabled before a persona existed: deactivate one.
    PersonaActivator.new(@collective, Personas::MELODY).deactivate_persona!
    assert_nil @collective.reload.persona_user("melody"), "precondition"

    PersonaActivator.reconcile!(@collective)

    assert_not_nil @collective.reload.persona_user("melody"),
                   "reconcile must activate personas missing from an enabled ensemble"
  end

  test "activate! sets the explicit trio feature flag to true" do
    PersonaActivator.activate!(@collective)

    assert_equal true, @collective.reload.settings.dig("feature_flags", "trio")
  end

  test "deactivate! sets the explicit trio feature flag to false" do
    PersonaActivator.activate!(@collective)
    PersonaActivator.deactivate!(@collective)

    assert_equal false, @collective.reload.settings.dig("feature_flags", "trio")
  end

  # === activate! after deactivate! (restore) ===

  test "activate! after deactivate! restores the previous persona users" do
    PersonaActivator.activate!(@collective)
    original_ids = @collective.reload.persona_users.map(&:id).sort

    PersonaActivator.deactivate!(@collective)
    PersonaActivator.activate!(@collective)

    restored_ids = @collective.reload.persona_users.map(&:id).sort
    assert_equal original_ids, restored_ids, "expected the original persona users to be restored"
  end

  test "activate! after deactivate! re-enables the previous automation rules" do
    PersonaActivator.activate!(@collective)
    agent_ids = @collective.reload.persona_users.map(&:id)
    rule_ids = AutomationRule.where(ai_agent_id: agent_ids).pluck(:id)

    PersonaActivator.deactivate!(@collective)
    PersonaActivator.activate!(@collective)

    AutomationRule.where(id: rule_ids).each do |r|
      assert r.enabled?, "expected rule #{r.id} to be re-enabled"
    end
  end

  test "activate! after deactivate! preserves user-edited rule customizations" do
    PersonaActivator.activate!(@collective)
    agent = T.must(cadence_user)
    rule = T.must(AutomationRule.where(ai_agent_id: agent.id).first)
    customized_actions = { "task" => "custom user-edited task" }
    rule.update!(actions: customized_actions, name: "Custom Name")

    PersonaActivator.deactivate!(@collective)
    PersonaActivator.activate!(@collective)

    rule.reload
    assert_equal customized_actions, rule.actions, "expected user customizations to survive deactivate/activate cycle"
    assert_equal "Custom Name", rule.name
  end

  test "activate! after deactivate! unarchives the personas' CollectiveMembers" do
    PersonaActivator.activate!(@collective)
    agent = T.must(cadence_user)

    PersonaActivator.deactivate!(@collective)
    member = T.must(@collective.collective_members.find_by(user_id: agent.id))
    assert_not_nil member.archived_at, "precondition: member should be archived"

    PersonaActivator.activate!(@collective)

    assert_nil member.reload.archived_at, "expected CollectiveMember to be unarchived"
  end

  # === Activation roles (mention resolution and capabilities key off them) ===

  test "activate! grants each persona its persona, ensemble, and capability roles" do
    PersonaActivator.activate!(@collective)

    expectations = {
      "melody" => "automator",
      "counterpoint" => "moderator",
      "cadence" => "summarizer",
    }
    expectations.each do |persona_role, capability_role|
      agent = T.must(@collective.reload.persona_user(persona_role))
      member = T.must(@collective.collective_members.find_by(user_id: agent.id))
      assert member.has_role?(persona_role), "#{persona_role}: persona role"
      assert member.has_role?("trio"), "#{persona_role}: ensemble role — @trio fans out to active personas"
      assert member.has_role?(capability_role), "#{persona_role}: capability role"
    end
  end

  test "deactivate! removes all activation roles" do
    PersonaActivator.activate!(@collective)
    agent = T.must(cadence_user)
    PersonaActivator.deactivate!(@collective)

    member = T.must(@collective.collective_members.find_by(user_id: agent.id))
    assert_not member.has_role?("cadence"), "a deactivated persona must drop its persona role"
    assert_not member.has_role?("trio"), "a deactivated persona must drop the ensemble role"
    assert_not member.has_role?("summarizer"), "a deactivated persona must drop its capability role"
  end

  test "reactivation restores all activation roles" do
    PersonaActivator.activate!(@collective)
    agent = T.must(cadence_user)
    PersonaActivator.deactivate!(@collective)
    PersonaActivator.activate!(@collective)

    member = T.must(@collective.collective_members.find_by(user_id: agent.id))
    assert member.has_role?("cadence")
    assert member.has_role?("trio")
    assert member.has_role?("summarizer")
  end

  test "all active personas hold the ensemble role" do
    PersonaActivator.activate!(@collective)

    holders = @collective.reload.users_with_role("trio")
    assert_equal @collective.persona_users.map(&:id).sort, holders.map(&:id).sort
    assert_equal 3, holders.size
  end

  # === Auto-funding from the collective's pool ===

  def open_pool!
    FundingPool.create!(tenant: @tenant, collective: @collective, created_by: @owner, member_draw_cap_cents: 500)
  end

  test "activating with an open pool puts every persona on the pool payroll" do
    pool = open_pool!

    agents = PersonaActivator.activate!(@collective)

    assert_equal 3, agents.size
    agents.each do |agent|
      assert_equal pool.id, agent.reload.funding_pool_id, "#{agent.system_role} should be pool-funded"
    end
  end

  test "reactivating reattaches personas to the pool" do
    pool = open_pool!
    PersonaActivator.activate!(@collective)
    agent = T.must(cadence_user)
    PersonaActivator.deactivate!(@collective)
    agent.update!(funding_pool_id: nil)

    PersonaActivator.activate!(@collective)

    assert_equal pool.id, agent.reload.funding_pool_id
  end

  test "activating without a pool leaves the personas unfunded" do
    agents = PersonaActivator.activate!(@collective)

    agents.each { |agent| assert_nil agent.funding_pool_id }
  end

  test "activating with a closed pool leaves the personas unfunded" do
    pool = open_pool!
    pool.archive!

    agents = PersonaActivator.activate!(@collective)

    agents.each { |agent| assert_nil agent.reload.funding_pool_id }
  end

  test "deactivating leaves personas attached to the pool" do
    pool = open_pool!
    PersonaActivator.activate!(@collective)
    agent = T.must(cadence_user)

    PersonaActivator.deactivate!(@collective)

    assert_equal pool.id, agent.reload.funding_pool_id
  end
end
