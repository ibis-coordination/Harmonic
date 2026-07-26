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
         params: { voter_eligibility: "user:#{alice_handle}" },
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
    assert_nil decision.voter_eligibility
  end

  test "sets a multi-clause union" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "user:#{alice_handle} role:admin" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal 2, rule["any_of"].size
  end

  test "rejects an unresolvable handle and leaves the rule alone" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "user:nobody-at-all" },
         headers: { "Accept" => "text/markdown" }

    assert_response :unprocessable_content
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_nil rule
  end

  test "rejects a clause naming a non-member" do
    outsider = create_user(email: "out-#{SecureRandom.hex(4)}@example.com", name: "Outsider")
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "user:#{outsider.id}" },
         headers: { "Accept" => "text/markdown" }

    assert_response :unprocessable_content
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_nil rule
  end

  test "an explicit empty value lifts the restriction" do
    scoped do
      Decision.find(@decision.id)
        .update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] })
    end
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_nil scoped { Decision.find(@decision.id).voter_eligibility }
  end

  test "clearing the field resets the rule to open" do
    scoped do
      Decision.find(@decision.id)
        .update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] })
    end
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
         params: { question: @decision.question, voter_eligibility: "", deadline_option: "1_week" }

    assert_response :redirect
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_nil rule, "clearing the field must remove the restriction, not silently keep it"
  end

  test "omitting the param entirely leaves the rule alone" do
    scoped do
      Decision.find(@decision.id)
        .update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] })
    end
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { question: "Still restricted?" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] }, rule)
  end

  # ---- audit ----

  test "an eligibility change is audited as JSON, not a Ruby hash literal" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { voter_eligibility: "user:#{alice_handle}" },
         headers: { "Accept" => "text/markdown" }
    assert_response :success

    entry = scoped { DecisionAuditEntry.where(decision_id: @decision.id, action: "decision_updated").last }
    assert_not_nil entry
    before, after = entry.metadata["voter_eligibility"]

    assert_nil before
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] }, JSON.parse(after))
  end

  test "creation omits absent rules from the audit metadata" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide/actions/create_decision",
         params: { question: "Fresh?", description: "d", deadline: "7d" },
         headers: { "Accept" => "text/markdown" }
    assert_response :success

    entry = scoped { DecisionAuditEntry.where(action: "decision_created").order(:created_at).last }
    assert_not entry.metadata.key?("voter_eligibility")
    assert_not entry.metadata.key?("proposer_eligibility")
  end

  test "creation records a rule that is set" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide/actions/create_decision",
         params: { question: "Born restricted?", deadline: "7d",
                   voter_eligibility: "user:#{alice_handle}", },
         headers: { "Accept" => "text/markdown" }
    assert_response :success

    entry = scoped { DecisionAuditEntry.where(action: "decision_created").order(:created_at).last }
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
                 JSON.parse(entry.metadata["voter_eligibility"]))
  end

  # ---- create_decision ----

  test "creates a decision with a restricted electorate" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide/actions/create_decision",
         params: { question: "Restricted from birth?", deadline: "7d",
                   voter_eligibility: "user:#{alice_handle}", },
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
         params: { decision: { voter_eligibility: "user:#{alice_handle}" } }

    assert_response :redirect
    rule = scoped { Decision.find(@decision.id).voter_eligibility }
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] }, rule)
  end

  # ---- HTML forms ----

  test "the settings form submits unprefixed field names, as it renders them" do
    sign_in_as(@user, tenant: @tenant)

    # The form is form_with(url:) with no model, so fields are top-level rather
    # than nested under decision[...]. Post exactly what the browser would.
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
         params: { question: @decision.question, voter_eligibility: "user:#{alice_handle}",
                   proposer_eligibility: "role:admin", deadline_option: "1_week", }

    assert_response :redirect
    decision = scoped { Decision.find(@decision.id) }
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
                 decision.voter_eligibility)
    assert_equal({ "any_of" => [{ "type" => "role", "role" => "admin" }] },
                 decision.proposer_eligibility)
  end

  test "the settings form shows the current rules in the compact grammar" do
    scoped do
      Decision.find(@decision.id)
        .update!(voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] })
    end
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings"

    assert_response :success
    assert_match(/name="voter_eligibility"/, response.body)
    assert_match(/value="user:#{Regexp.escape(alice_handle)}"/, response.body)
  end

  test "neither form still offers the superseded options_open dropdown" do
    sign_in_as(@user, tenant: @tenant)

    # "who can add options" is proposer_eligibility now; creator-only is
    # expressible as user:<creator>. options_open survives as a column and an
    # API param for export/import and audit-metadata compatibility, but two
    # controls for one question is one too many.
    get "/collectives/#{@collective.handle}/decide"
    assert_response :success
    assert_no_match(/name="options_open"/, response.body)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings"
    assert_response :success
    assert_no_match(/name="options_open"/, response.body)
  end

  test "saving settings without options_open leaves it alone" do
    scoped { Decision.find(@decision.id).update!(options_open: false) }
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
         params: { question: @decision.question, deadline_option: "1_week" }

    assert_response :redirect
    assert_equal false, scoped { Decision.find(@decision.id).options_open }
  end

  test "the new-decision form offers both eligibility fields" do
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/decide"

    assert_response :success
    assert_match(/name="voter_eligibility"/, response.body)
    assert_match(/name="proposer_eligibility"/, response.body)
  end

  test "the new-decision form creates a restricted decision" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide",
         params: { question: "From the form?", voter_eligibility: "user:#{alice_handle}",
                   deadline_option: "1_week", }

    decision = scoped { Decision.where(question: "From the form?").last }
    assert_not_nil decision
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
                 decision.voter_eligibility)
  end

  test "options_open is refused with a pointer to proposer_eligibility" do
    sign_in_as(@user, tenant: @tenant)

    # Silently creating an open decision would hand back something other than
    # what was asked for, so the parameter is refused rather than ignored.
    assert_no_difference -> { scoped { Decision.where(question: "Creator only?").count } } do
      post "/collectives/#{@collective.handle}/decide/actions/create_decision",
           params: { question: "Creator only?", deadline: "7d", options_open: false }.to_json,
           headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }
    end

    assert_response :unprocessable_content
    assert_match(/proposer_eligibility/, response.body)
  end

  test "options_open is refused on the settings action too" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { options_open: false }.to_json,
         headers: { "Accept" => "text/markdown", "Content-Type" => "application/json" }

    assert_response :unprocessable_content
    assert_match(/proposer_eligibility/, response.body)
  end

  test "a decision that already has options_open false keeps it" do
    scoped { Decision.find(@decision.id).update!(options_open: false) }
    sign_in_as(@user, tenant: @tenant)

    # The column still governs historical decisions; only the parameter is gone.
    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings/actions/update_decision_settings",
         params: { question: "Renamed" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_equal false, scoped { Decision.find(@decision.id).options_open }
  end

  # ---- duplicate ----

  test "duplicating a restricted decision keeps both electorates" do
    scoped do
      Decision.find(@decision.id).update!(
        voter_eligibility: { "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
        proposer_eligibility: { "any_of" => [{ "type" => "role", "role" => "admin" }] }
      )
    end
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/duplicate"

    assert_response :redirect
    copy = scoped { Decision.where(question: "#{@decision.question} (copy)").last }
    assert_not_nil copy
    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
                 copy.voter_eligibility,
                 "a copy that quietly opens up the electorate is worse than no copy")
    assert_equal({ "any_of" => [{ "type" => "role", "role" => "admin" }] },
                 copy.proposer_eligibility)
  end

  # ---- HTML forms: unparseable input ----
  #
  # A typo'd handle is ordinary user error on a free-text field, so it belongs in
  # the form's error path. Reaching the exception handler instead loses the whole
  # draft.

  test "the new-decision form reports an unresolvable handle instead of erroring" do
    sign_in_as(@user, tenant: @tenant)

    assert_no_difference -> { scoped { Decision.where(question: "Typo?").count } } do
      post "/collectives/#{@collective.handle}/decide",
           params: { question: "Typo?", proposer_eligibility: "user:@asfasdfsd",
                     deadline_option: "1_week", }
    end

    assert_response :unprocessable_entity
    assert_match(/asfasdfsd/, response.body)
  end

  test "the new-decision form keeps what was typed so it can be corrected" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide",
         params: { question: "Typo?", proposer_eligibility: "user:@asfasdfsd",
                   voter_eligibility: "role:admin", deadline_option: "1_week", }

    assert_response :unprocessable_entity
    assert_match(/value="user:@asfasdfsd"/, response.body)
    assert_match(/value="role:admin"/, response.body,
                 "the field that parsed fine must survive the round trip too")
  end

  test "the settings form reports an unresolvable handle instead of erroring" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
         params: { question: @decision.question, voter_eligibility: "user:@asfasdfsd",
                   deadline_option: "1_week", }

    assert_response :unprocessable_entity
    assert_match(/asfasdfsd/, response.body)
    assert_nil scoped { Decision.find(@decision.id).voter_eligibility }
  end

  test "a parse failure names the field, since both are on the form at once" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide",
         params: { question: "Typo?", proposer_eligibility: "user:@asfasdfsd",
                   voter_eligibility: "role:admin", deadline_option: "1_week", }

    assert_response :unprocessable_entity
    assert_match(/proposer_eligibility.*asfasdfsd/i, response.body)
  end

  test "the create_decision action reports an unresolvable handle instead of erroring" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/decide/actions/create_decision",
         params: { question: "Typo?", deadline: "7d", voter_eligibility: "user:@asfasdfsd" },
         headers: { "Accept" => "text/markdown" }

    assert_response :unprocessable_content
    assert_match(/asfasdfsd/, response.body)
  end
end
