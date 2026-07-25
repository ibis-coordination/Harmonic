# typed: false

require "test_helper"

# The cast_vote! guard is the last line of defense for voter eligibility: every
# vote write in the app funnels through it, including the REST-compat single
# vote and the HTML ballot.
class DecisionVoterEligibilityTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
  end

  def make_user(suffix = SecureRandom.hex(4))
    user = create_user(email: "u-#{suffix}@example.com", name: "U #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def participant_for(user, decision: @decision)
    DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
  end

  def build_vote(user, decision: @decision, option: @option)
    Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option, decision_participant: participant_for(user, decision: decision),
      accepted: 1, preferred: 0,
    )
  end

  def restrict_voting_to(*users)
    @decision.update!(voter_eligibility: {
      "any_of" => [{ "type" => "users", "user_ids" => users.map(&:id) }],
    })
  end

  # ---- default behavior ----

  test "the default rule lets any member vote" do
    member = make_user
    vote = build_vote(member)

    assert_nothing_raised do
      DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: member)
    end
    assert vote.persisted?
  end

  # ---- the guard ----

  test "an ineligible user cannot cast a vote" do
    alice = make_user("alice")
    bob = make_user("bob")
    restrict_voting_to(alice)
    vote = build_vote(bob)

    error = assert_raises(ArgumentError) do
      DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: bob)
    end
    assert_match(/eligible/i, error.message)
    assert_not vote.persisted?
  end

  test "an eligible user can cast a vote" do
    alice = make_user("alice")
    restrict_voting_to(alice)
    vote = build_vote(alice)

    assert_nothing_raised do
      DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: alice)
    end
    assert vote.persisted?
  end

  test "a user matching any clause of a union can vote" do
    alice = make_user("alice")
    admin = make_user("admin")
    @collective.collective_members.find_by(user: admin).add_role!("admin")
    @decision.update!(voter_eligibility: { "any_of" => [
      { "type" => "users", "user_ids" => [alice.id] },
      { "type" => "role", "role" => "admin" },
    ] })

    [alice, admin].each do |user|
      vote = build_vote(user)
      assert_nothing_raised do
        DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: user)
      end
    end
  end

  test "no vote or audit entry is written when the guard rejects" do
    alice = make_user("alice")
    bob = make_user("bob")
    restrict_voting_to(alice)
    vote = build_vote(bob)

    assert_no_difference ["Vote.count", "DecisionAuditEntry.where(decision_id: @decision.id).count"] do
      assert_raises(ArgumentError) do
        DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: bob)
      end
    end
  end

  # ---- the subject is the participant, not the actor ----

  test "eligibility follows the participant's user, not the acting trustee" do
    alice = make_user("alice")
    trustee = make_user("trustee")
    restrict_voting_to(alice)
    vote = build_vote(alice)

    # A trustee acting for Alice is judged against Alice's eligibility.
    assert_nothing_raised do
      DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: trustee)
    end
    assert vote.persisted?
  end

  test "an eligible trustee cannot vote on behalf of an ineligible user" do
    alice = make_user("alice")
    bob = make_user("bob")
    restrict_voting_to(alice)
    vote = build_vote(bob)

    assert_raises(ArgumentError) do
      DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: alice)
    end
  end

  # ---- subtypes ----

  test "executive selections are not blocked by voter eligibility" do
    decision_maker = make_user("dm")
    executive = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      decision_maker: decision_maker, subtype: "executive",
      question: "Executive?", deadline: 1.week.from_now, options_open: false,
    )
    option = create_option(decision: executive, created_by: @user, title: "Only")
    # A restrictive rule the decision maker does not match. Validation refuses
    # this on an executive decision, so write it the only way it can occur in
    # practice — an import, which saves without validating.
    executive.update_column(
      :voter_eligibility, { "any_of" => [{ "type" => "users", "user_ids" => [@user.id] }] }
    )
    executive.reload
    vote = build_vote(decision_maker, decision: executive, option: option)

    assert_nothing_raised do
      DecisionActionService.cast_vote!(decision: executive, vote: vote, actor: decision_maker)
    end
    assert vote.persisted?
  end
end
