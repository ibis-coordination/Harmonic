# frozen_string_literal: true

require "test_helper"

# Proposer eligibility restricts who may put options on the ballot. It composes
# with options_open rather than replacing it: options_open is the coarse switch
# (everyone / creator only), eligibility the fine-grained restriction.
class DecisionProposerEligibilityTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @decision = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Who proposes?", description: "A decision with a proposer rule",
      deadline: 1.week.from_now, options_open: true
    )
    @alice = make_member("alice")
    @bob = make_member("bob")
  end

  def teardown
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def make_member(suffix)
    user = create_user(email: "p-#{suffix}-#{SecureRandom.hex(4)}@example.com", name: "P #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def participant_for(user, decision: @decision)
    DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
  end

  # Signing in as another user leaves the thread unscoped, so reads that follow
  # a request have to re-scope to see the decision's collective.
  def scoped
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    yield
  ensure
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def restrict_proposing_to(*users, decision: @decision)
    decision.update!(proposer_eligibility: {
      "any_of" => [{ "type" => "users", "user_ids" => users.map(&:id) }],
    })
  end

  # ---- can_add_options? ----

  test "the default rule lets any member add options" do
    assert @decision.can_add_options?(participant_for(@bob))
  end

  test "an ineligible member cannot add options" do
    restrict_proposing_to(@alice)

    assert @decision.can_add_options?(participant_for(@alice))
    assert_not @decision.can_add_options?(participant_for(@bob))
  end

  test "a member matching any clause of a union can add options" do
    admin = make_member("admin")
    @collective.collective_members.find_by(user: admin).add_role!("admin")
    @decision.update!(proposer_eligibility: { "any_of" => [
      { "type" => "users", "user_ids" => [@alice.id] },
      { "type" => "role", "role" => "admin" },
    ] })

    assert @decision.can_add_options?(participant_for(@alice))
    assert @decision.can_add_options?(participant_for(admin))
    assert_not @decision.can_add_options?(participant_for(@bob))
  end

  # ---- composition with options_open ----

  test "options_open false still restricts to the creator under an open rule" do
    @decision.update!(options_open: false)

    assert @decision.can_add_options?(participant_for(@user))
    assert_not @decision.can_add_options?(participant_for(@bob))
  end

  test "options_open false and a rule naming the creator lets the creator add" do
    @decision.update!(options_open: false)
    restrict_proposing_to(@user)

    assert @decision.can_add_options?(participant_for(@user))
  end

  test "a proposer set supersedes options_open false" do
    @decision.update!(options_open: false)
    restrict_proposing_to(@alice)

    # options_open can no longer be set by anyone, so a decision carrying false
    # from before would otherwise be creator-only forever, whatever set is
    # named. The explicit control wins over the vestigial one — which is also
    # what stops the conjunction resolving to nobody.
    assert @decision.can_add_options?(participant_for(@alice))
    assert_not @decision.can_add_options?(participant_for(@user))
  end

  test "options_open false still governs when no proposer set is named" do
    @decision.update!(options_open: false)

    assert @decision.can_add_options?(participant_for(@user))
    assert_not @decision.can_add_options?(participant_for(@bob))
  end

  test "a closed decision refuses options regardless of the rule" do
    restrict_proposing_to(@alice)
    @decision.update!(deadline: 1.day.ago)

    assert_not @decision.can_add_options?(participant_for(@alice))
  end

  # ---- lottery entries ----

  test "lottery entries respect proposer eligibility" do
    lottery = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      subtype: "lottery", question: "Who enters?", deadline: 1.week.from_now, options_open: true
    )
    restrict_proposing_to(@alice, decision: lottery)

    assert lottery.can_add_options?(participant_for(@alice, decision: lottery))
    assert_not lottery.can_add_options?(participant_for(@bob, decision: lottery))
  end

  # ---- ActionAuthorization ----

  test "the add_options action is denied for an ineligible member" do
    restrict_proposing_to(@alice)
    context = { collective: @collective, resource: @decision }

    assert ActionAuthorization.authorized?("add_options", @alice, context)
    assert_not ActionAuthorization.authorized?("add_options", @bob, context)
  end

  test "the add_options action stays permissive for listings with no resource" do
    restrict_proposing_to(@alice)

    assert ActionAuthorization.authorized?("add_options", @bob, { collective: @collective })
  end

  test "the add_options action is unaffected by the default rule" do
    context = { collective: @collective, resource: @decision }

    assert ActionAuthorization.authorized?("add_options", @bob, context)
  end

  # ---- end to end ----

  test "the add_options action returns 403 for an ineligible member" do
    restrict_proposing_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_options",
         params: { titles: ["Sneaky"] },
         headers: { "Accept" => "text/markdown" }

    assert_response :forbidden
  end

  test "an eligible member can add options through the action" do
    restrict_proposing_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@alice, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/actions/add_options",
         params: { titles: ["Legitimate"] },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    assert Option.where(decision_id: @decision.id, title: "Legitimate").exists?
  end

  test "an ineligible member cannot add an option through the HTML route" do
    restrict_proposing_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    # Hiding the form is not enforcement; the route has to refuse the post.
    assert_no_difference -> { scoped { Option.where(decision_id: @decision.id).count } } do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/options.html",
           params: { title: "Snuck in" }
    end

    assert_response :forbidden
  end

  test "an eligible member can add an option through the HTML route" do
    restrict_proposing_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@alice, tenant: @tenant)

    assert_difference -> { scoped { Option.where(decision_id: @decision.id).count } }, 1 do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/options.html",
           params: { title: "Allowed" }
    end

    assert_response :success
  end

  test "the HTML route refuses an option on a closed decision without erroring" do
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@alice, tenant: @tenant)
    scoped { @decision.update!(deadline: 1.day.ago) }

    # can_add_options? refuses for reasons other than eligibility too, and they
    # reach the same raise in the API helper.
    assert_no_difference -> { scoped { Option.where(decision_id: @decision.id).count } } do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/options.html",
           params: { title: "Too late" }
    end

    assert_response :forbidden
  end

  test "the HTML route refuses a non-creator under options_open false without erroring" do
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@alice, tenant: @tenant)
    scoped { @decision.update!(options_open: false) }

    assert_no_difference -> { scoped { Option.where(decision_id: @decision.id).count } } do
      post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/options.html",
           params: { title: "Not mine to add" }
    end

    assert_response :forbidden
  end

  test "an ineligible member does not see the add-option form" do
    restrict_proposing_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_no_match(/pulse-add-option-input/, response.body)
  end

  test "an eligible member sees the add-option form" do
    restrict_proposing_to(@alice)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
    sign_in_as(@alice, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_match(/pulse-add-option-input/, response.body)
  end
end
