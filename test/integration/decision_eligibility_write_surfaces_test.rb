# frozen_string_literal: true

require "test_helper"

# Setting an electorate through the agent-facing surfaces, and the audit trail
# that has to record it.
class DecisionEligibilityWriteSurfacesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @decision = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Settable?", description: "A decision whose electorate is edited",
      deadline: 1.week.from_now
    )
    @alice = make_member("alice")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def teardown
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def make_member(suffix)
    user = create_user(email: "w-#{suffix}-#{SecureRandom.hex(4)}@example.com", name: "W #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def scoped
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    yield
  ensure
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def alice_handle
    scoped { @alice.tenant_user.handle }
  end

  # ---- update_decision_settings ----

  test "sets voter eligibility from the compact grammar" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "users:#{alice_handle}" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] }, rule)
  end

  test "sets proposer eligibility independently of voter eligibility" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { proposer_eligibility: "role:admin" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    decision = scoped { Decision.find(@decision.id) }
    assert_equal({ "any_of" => [{ "type" => "role", "role" => "admin" }] }, decision.proposer_eligibility)
    assert_equal({ "any_of" => [{ "type" => "open" }] }, decision.voter_eligibility)
  end

  test "sets a multi-clause union" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "users:#{alice_handle} role:admin" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal 2, rule["any_of"].size
  end

  test "rejects an unresolvable handle and leaves the rule alone" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "users:nobody-at-all" },
         headers: { "Accept" => "text/markdown" }

    assert_response :unprocessable_content
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal({ "any_of" => [{ "type" => "open" }] }, rule)
  end

  test "rejects a clause naming a non-member" do
    outsider = create_user(email: "out-#{SecureRandom.hex(4)}@example.com", name: "Outsider")
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "users:#{outsider.id}" },
         headers: { "Accept" => "text/markdown" }

    assert_response :unprocessable_content
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal({ "any_of" => [{ "type" => "open" }] }, rule)
  end

  test "resets to open" do
    scoped do
      Decision.find(@decision.id)
        .update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] })
    end
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "open" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal({ "any_of" => [{ "type" => "open" }] }, rule)
  end

  # ---- audit ----

  test "an eligibility change is audited as JSON, not a Ruby hash literal" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "users:#{alice_handle}" },
         headers: { "Accept" => "text/markdown" }
    assert_response :success

    entry = scoped { DecisionAuditEntry.where(decision_id: @decision.id, action: "decision_updated").last }
    assert_not_nil entry
    before, after = entry.metadata["voter_eligibility"]

    assert_equal({ "any_of" => [{ "type" => "open" }] }, JSON.parse(before))
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] }, JSON.parse(after))
  end

  test "creation records both rules in the audit metadata" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide/actions/create_decision",
         params: { question: "Fresh?", description: "d", deadline: "7d" },
         headers: { "Accept" => "text/markdown" }
    assert_response :success

    entry = scoped { DecisionAuditEntry.where(action: "decision_created").order(:created_at).last }
    assert_equal({ "any_of" => [{ "type" => "open" }] }, JSON.parse(entry.metadata["voter_eligibility"]))
    assert_equal({ "any_of" => [{ "type" => "open" }] }, JSON.parse(entry.metadata["proposer_eligibility"]))
  end

  # ---- create_decision ----

  test "creates a decision with a restricted electorate" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide/actions/create_decision",
         params: { question: "Restricted from birth?", deadline: "7d",
                   voter_eligibility: "users:#{alice_handle}", },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    decision = scoped { Decision.where(question: "Restricted from birth?").last }
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
                 decision.voter_eligibility)
  end

  test "rejects an invalid rule at creation" do
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference -> { scoped { Decision.where(question: "Bad rule?").count } } do
      post "/collectives/#{@collective.handle}/decide/actions/create_decision",
           params: { question: "Bad rule?", deadline: "7d", voter_eligibility: "role:wizard" },
           headers: { "Accept" => "text/markdown" }
    end

    assert_response :unprocessable_content
  end

  # ---- HTML settings form ----

  test "the settings form updates the electorate" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
         params: { decision: { voter_eligibility: "users:#{alice_handle}" } }

    assert_response :redirect
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] }, rule)
  end

  # ---- HTML forms ----

  test "the settings form shows the current rules in the compact grammar" do
    scoped do
      Decision.find(@decision.id)
        .update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] })
    end
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings"

    assert_response :success
    assert_match(/name="voter_eligibility"/, response.body)
    assert_match(/value="users:#{Regexp.escape(alice_handle)}"/, response.body)
  end

  test "the new-decision form offers both eligibility fields defaulted to open" do
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/decide"

    assert_response :success
    assert_match(/name="voter_eligibility"/, response.body)
    assert_match(/name="proposer_eligibility"/, response.body)
  end

  test "the new-decision form creates a restricted decision" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide",
         params: { question: "From the form?", voter_eligibility: "users:#{alice_handle}",
                   deadline_option: "1_week", }

    decision = scoped { Decision.where(question: "From the form?").last }
    assert_not_nil decision
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
                 decision.voter_eligibility)
  end
end
