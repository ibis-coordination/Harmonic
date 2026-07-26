# frozen_string_literal: true

require "test_helper"

# Voter eligibility is enforced in layers: ActionAuthorization hides and denies
# the `vote` action, the HTML ballot stops posting, and cast_vote! backstops
# both. This covers the outer two — the guard itself is in
# test/services/decision_voter_eligibility_test.rb.
class DecisionVoterEligibilityEnforcementTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @decision = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Restricted?", description: "A decision with an electorate",
      deadline: 1.week.from_now
    )
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    @option = Option.create!(decision: @decision, decision_participant: participant, title: "Option A")

    @alice = make_member("alice")
    @bob = make_member("bob")
  end

  def teardown
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def make_member(suffix)
    user = create_user(email: "u-#{suffix}-#{SecureRandom.hex(4)}@example.com", name: "U #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def restrict_voting_to(*users)
    @decision.update!(voter_eligibility: {
      "any_of" => [{ "type" => "users", "user_ids" => users.map(&:id) }],
    })
  end

  def restrict_proposing_to(*users)
    @decision.update!(proposer_eligibility: {
      "any_of" => [{ "type" => "users", "user_ids" => users.map(&:id) }],
    })
  end

  def scoped
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    yield
  ensure
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # ---- ActionAuthorization ----

  test "the vote action is authorized for an eligible member" do
    restrict_voting_to(@alice)
    context = { collective: @collective, resource: @decision }

    assert ActionAuthorization.authorized?("vote", @alice, context)
  end

  test "the vote action is denied for an ineligible member" do
    restrict_voting_to(@alice)
    context = { collective: @collective, resource: @decision }

    assert_not ActionAuthorization.authorized?("vote", @bob, context)
  end

  test "the vote action is denied for a non-member regardless of the rule" do
    outsider = create_user(email: "out-#{SecureRandom.hex(4)}@example.com", name: "Outsider")
    context = { collective: @collective, resource: @decision }

    assert_not ActionAuthorization.authorized?("vote", outsider, context)
  end

  test "the vote action stays permissive for listings with no resource" do
    restrict_voting_to(@alice)

    assert ActionAuthorization.authorized?("vote", @bob, { collective: @collective })
  end

  test "the vote action is unaffected when the rule is left at its default" do
    context = { collective: @collective, resource: @decision }

    assert ActionAuthorization.authorized?("vote", @alice, context)
    assert ActionAuthorization.authorized?("vote", @bob, context)
  end

  test "a non-Decision resource leaves the eligibility check out of it" do
    restrict_voting_to(@alice)
    participant = scoped do
      DecisionParticipantManager.new(decision: @decision, user: @bob).find_or_create_participant
    end

    # cast_vote! is the guard on routes that resolve a participant as the resource.
    assert ActionAuthorization.authorized?("vote", @bob, { collective: @collective, resource: participant })
  end

  # ---- HTML ballot ----

  test "an ineligible member cannot submit votes through the HTML ballot" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    assert_no_difference -> { scoped { Vote.where(decision_id: @decision.id).count } } do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
           params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }
    end

    assert_redirected_to @decision.path
    assert_match(/eligible/i, flash[:alert].to_s)
  end

  test "a rejected ballot submission writes nothing, not even a participant" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    # The receipt-email preference is saved before the votes are cast, so a
    # guard that only fires inside cast_vote! still leaves this behind.
    assert_no_difference -> { scoped { DecisionParticipant.where(decision_id: @decision.id).count } } do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
           params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }],
                     vote_receipt_email: "1", }
    end

    assert_response :redirect
  end

  test "a non-member cannot submit votes through the HTML ballot" do
    outsider = create_user(email: "out-#{SecureRandom.hex(4)}@example.com", name: "Outsider")
    @tenant.add_user!(outsider)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(outsider, tenant: @tenant)

    # The `vote` action declares :collective_member; the ballot must not be a
    # way around it, rule or no rule.
    assert_no_difference -> { scoped { Vote.where(decision_id: @decision.id).count } } do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
           params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }
    end
  end

  test "an eligible member can submit votes through the HTML ballot" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@alice, tenant: @tenant)

    assert_difference -> { scoped { Vote.where(decision_id: @decision.id).count } }, 1 do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
           params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }
    end

    assert_response :redirect
  end

  test "the default rule still lets any member submit votes" do
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    assert_difference -> { scoped { Vote.where(decision_id: @decision.id).count } }, 1 do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/submit_votes",
           params: { votes: [{ option_title: "Option A", accepted: "1", preferred: "0" }] }
    end

    assert_response :redirect
  end

  # ---- ballot rendering ----

  test "an ineligible member sees the options but no ballot" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_match(/Option A/, response.body)
    assert_match(/restricted/i, response.body)
    assert_no_match(/name="votes\[0\]\[accepted\]"/, response.body)
  end

  test "an eligible member sees the ballot" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@alice, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_match(/name="votes\[0\]\[accepted\]"/, response.body)
  end

  test "an ineligible member gets no vote control of any kind" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_no_match(/pulse-acceptance-checkbox/, response.body, "no accept checkbox")
    assert_no_match(/pulse-star-checkbox/, response.body, "no preference star")
    assert_no_match(/submit_votes/, response.body, "no ballot form to post")
    assert_no_match(/name="vote_receipt_email"/, response.body, "no receipt option")
  end

  # The two sets are independent, so each control has to follow its own rule
  # rather than a single "can participate" notion.

  test "a member who may vote but not propose sees the ballot and no add-option input" do
    restrict_voting_to(@bob)
    restrict_proposing_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_match(/pulse-acceptance-checkbox/, response.body)
    assert_no_match(/pulse-add-option-input/, response.body)
  end

  test "a member who may propose but not vote sees the add-option input and no ballot" do
    restrict_voting_to(@alice)
    restrict_proposing_to(@bob)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_match(/pulse-add-option-input/, response.body)
    assert_no_match(/pulse-acceptance-checkbox/, response.body)
  end

  test "the live options refresh is read-only for an ineligible member" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/options.html"

    assert_response :success
    assert_match(/Option A/, response.body)
    assert_no_match(/name="votes\[0\]\[accepted\]"/, response.body)
  end

  test "the actions index offers vote to an eligible member and not an ineligible one" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # The agent-facing UI is the actions index, so it has to track eligibility
    # the way the ballot does.
    sign_in_as(@bob, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions",
        headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_no_match(/actions\/vote/, response.body)

    sign_in_as(@alice, tenant: @tenant)
    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions",
        headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/actions\/vote/, response.body)
  end

  # ---- markdown action ----

  test "the vote action returns 403 for an ineligible member" do
    restrict_voting_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/vote",
         params: { votes: [{ option_title: "Option A", accept: true, prefer: false }] },
         headers: { "Accept" => "text/markdown" }

    assert_response :forbidden
  end
end
