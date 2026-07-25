require "test_helper"

class DecisionEligibilityTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision
  end

  def make_user(suffix = SecureRandom.hex(4))
    user = create_user(email: "u-#{suffix}@example.com", name: "U #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # ---- defaults ----

  test "a new decision is open to everyone for both voting and proposing" do
    assert_equal({ "any_of" => [{ "type" => "open" }] }, @decision.voter_eligibility)
    assert_equal({ "any_of" => [{ "type" => "open" }] }, @decision.proposer_eligibility)
  end

  test "default rules make any member eligible for both" do
    member = make_user
    assert @decision.eligible_voter?(member)
    assert @decision.eligible_proposer?(member)
  end

  test "nil user is never eligible" do
    assert_not @decision.eligible_voter?(nil)
    assert_not @decision.eligible_proposer?(nil)
  end

  # ---- predicates ----

  test "eligible_voter? honors a users clause" do
    alice = make_user("alice")
    bob = make_user("bob")
    @decision.update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [alice.id] }] })

    assert @decision.eligible_voter?(alice)
    assert_not @decision.eligible_voter?(bob)
  end

  test "eligible_proposer? honors a users clause" do
    alice = make_user("alice")
    bob = make_user("bob")
    @decision.update!(proposer_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [alice.id] }] })

    assert @decision.eligible_proposer?(alice)
    assert_not @decision.eligible_proposer?(bob)
  end

  test "the two rule sets are independent" do
    voter = make_user("voter")
    proposer = make_user("proposer")
    @decision.update!(
      voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [voter.id] }] },
      proposer_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [proposer.id] }] },
    )

    assert @decision.eligible_voter?(voter)
    assert_not @decision.eligible_proposer?(voter)
    assert @decision.eligible_proposer?(proposer)
    assert_not @decision.eligible_voter?(proposer)
  end

  test "a union makes a member matching any clause eligible" do
    alice = make_user("alice")
    admin = make_user("admin")
    @collective.collective_members.find_by(user: admin).add_role!("admin")
    @decision.update!(voter_eligibility: { "any_of" => [
      { "type" => "users", "user_ids" => [alice.id] },
      { "type" => "role", "role" => "admin" },
    ] })

    assert @decision.eligible_voter?(alice)
    assert @decision.eligible_voter?(admin)
    assert_not @decision.eligible_voter?(make_user)
  end

  # ---- validation ----

  test "an unknown clause type is rejected" do
    @decision.voter_eligibility = { "any_of" => [{ "type" => "everyone" }] }
    assert_not @decision.valid?
    assert @decision.errors[:voter_eligibility].any?
  end

  test "an unknown role is rejected" do
    @decision.proposer_eligibility = { "any_of" => [{ "type" => "role", "role" => "wizard" }] }
    assert_not @decision.valid?
    assert @decision.errors[:proposer_eligibility].any?
  end

  test "a user who is not a collective member is rejected" do
    outsider = create_user(email: "out-#{SecureRandom.hex(4)}@example.com", name: "Outsider")
    @decision.voter_eligibility = { "any_of" => [{ "type" => "users", "user_ids" => [outsider.id] }] }
    assert_not @decision.valid?
    assert @decision.errors[:voter_eligibility].any?
  end

  test "an empty clause list is rejected" do
    @decision.voter_eligibility = { "any_of" => [] }
    assert_not @decision.valid?
    assert @decision.errors[:voter_eligibility].any?
  end

  test "open beside another clause is rejected" do
    @decision.voter_eligibility = { "any_of" => [
      { "type" => "open" },
      { "type" => "users", "user_ids" => [@user.id] },
    ] }
    assert_not @decision.valid?
    assert @decision.errors[:voter_eligibility].any?
  end

  test "a structurally malformed rule is rejected rather than raising" do
    @decision.voter_eligibility = { "type" => "open" }
    assert_not @decision.valid?
    assert @decision.errors[:voter_eligibility].any?
  end

  test "a valid rule saves" do
    alice = make_user("alice")
    @decision.voter_eligibility = { "any_of" => [{ "type" => "users", "user_ids" => [alice.id] }] }
    assert @decision.save
  end

  # ---- memoization ----

  test "repeated eligibility checks for the same user do not re-query" do
    listed = make_user
    list = UserList.create!(creator: @user, owner: @user, name: "Voters")
    UserListMember.create!(user_list: list, user: listed, added_by: @user)
    @decision.update!(voter_eligibility: { "any_of" => [{ "type" => "list", "list_id" => list.id }] })

    @decision.eligible_voter?(listed)
    repeat = count_queries { 5.times { @decision.eligible_voter?(listed) } }

    assert_equal 0, repeat
  end

  test "reload discards the memoized result" do
    alice = make_user("alice")
    assert @decision.eligible_voter?(alice)

    Decision.find(@decision.id)
      .update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@user.id] }] })
    @decision.reload

    assert_not @decision.eligible_voter?(alice)
  end

  test "assigning a new rule discards the memoized result" do
    alice = make_user("alice")
    assert @decision.eligible_voter?(alice)

    @decision.voter_eligibility = { "any_of" => [{ "type" => "users", "user_ids" => [@user.id] }] }
    assert_not @decision.eligible_voter?(alice)
  end

  # ---- rule accessors ----

  test "exposes parsed rules as EligibilityRule values" do
    assert_kind_of EligibilityRule, @decision.voter_eligibility_rule
    assert_kind_of EligibilityRule, @decision.proposer_eligibility_rule
  end
end
