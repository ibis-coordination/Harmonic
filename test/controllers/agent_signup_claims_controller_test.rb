# frozen_string_literal: true

require "test_helper"

class AgentSignupClaimsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @human = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    @tenant.set_feature_flag!("external_ai_agents", true)
    @tenant.set_feature_flag!("agent_signup", true)
    mark_activated!(@human)
    @signup = start_signup
  end

  def start_signup(email: @human.email, name: "Stickman", handle: "stickman")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    AgentSignup.start!(tenant: @tenant, principal_email: email, name: name, handle: handle)
  ensure
    Tenant.clear_thread_scope
  end

  def claim_path_for(signup = @signup)
    "/agent-signups/#{signup.public_id}/claim"
  end

  def accept(signup = @signup, **overrides)
    post claim_path_for(signup), params: {
      name: signup.proposed_name,
      handle: signup.proposed_handle,
      pairing_code: signup.pairing_code,
    }.merge(overrides)
  end

  def reload_signup(signup = @signup)
    AgentSignup.tenant_scoped_only(@tenant.id).find(signup.id)
  end

  def agents_of(user)
    User.where(user_type: "ai_agent", parent_id: user.id)
  end

  def other_member
    @other_member ||= create_user(email: "other-#{SecureRandom.hex(4)}@example.com", name: "Other Member").tap do |u|
      @tenant.add_user!(u)
      mark_activated!(u)
    end
  end

  def enable_stripe_billing_flag!(tenant)
    tenant.enable_feature_flag!("stripe_billing")
  end

  # ---------- reaching the claim page ----------

  test "claim page sends a logged-out visitor to login and brings them back afterwards" do
    get claim_path_for
    assert_redirected_to "/login"

    sign_in_as(@human, tenant: @tenant)
    assert_redirected_to claim_path_for
  end

  test "claim page requires reverification" do
    sign_in_as(@human, tenant: @tenant)

    get claim_path_for

    assert_response :redirect
    assert_match(/reverify/, response.location)
  end

  test "claim page shows the proposed name and handle to the named principal" do
    sign_in_with_ai_agents_reverify(@human)

    get claim_path_for

    assert_response :success
    assert_select "input[name=name][value=?]", "Stickman"
    assert_select "input[name=handle][value=?]", "stickman"
    assert_select "input[name=pairing_code]"
    assert_not_includes response.body, @signup.pairing_code
  end

  test "claim page escapes agent-supplied text" do
    signup = start_signup(name: "<script>alert(1)</script>", handle: nil)
    sign_in_with_ai_agents_reverify(@human)

    get claim_path_for(signup)

    assert_response :success
    assert_not_includes response.body, "<script>alert(1)</script>"
  end

  test "claim page is not found for an unknown signup" do
    sign_in_with_ai_agents_reverify(@human)

    get "/agent-signups/does-not-exist/claim"

    assert_response :not_found
  end

  test "claim page is not found when agent signup is off" do
    @tenant.set_feature_flag!("agent_signup", false)
    sign_in_with_ai_agents_reverify(@human)

    get claim_path_for

    assert_response :not_found
  end

  test "claim page tells any other member the request is not addressed to them" do
    sign_in_with_ai_agents_reverify(other_member)

    get claim_path_for

    assert_response :forbidden
    assert_includes response.body, "not addressed to you"
    assert_not_includes response.body, "Stickman"
    assert_select "title", text: /Claim agent/
  end

  test "claim page for a signup that matched no member reads the same as one addressed to someone else" do
    unmatched = start_signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")
    sign_in_with_ai_agents_reverify(@human)

    get claim_path_for(unmatched)

    assert_response :forbidden
    assert_includes response.body, "not addressed to you"
  end

  test "claim page reports an expired request" do
    sign_in_with_ai_agents_reverify(@human)

    travel 25.hours do
      # Reverification and the session both lapse over 25 hours; sign in again.
      sign_in_with_ai_agents_reverify(@human)
      get claim_path_for

      assert_response :gone
      assert_includes response.body, "expired"
    end
  end

  # ---------- accept ----------

  test "accept with the pairing code creates an external agent whose principal is the claimer" do
    sign_in_with_ai_agents_reverify(@human)

    assert_difference -> { agents_of(@human).count }, 1 do
      assert_no_difference -> { ApiToken.tenant_scoped_only(@tenant.id).count } do
        accept
      end
    end

    signup = reload_signup
    agent = signup.ai_agent_user
    assert_equal "claimed", signup.state
    assert_equal @human.id, agent.parent_id
    assert agent.external_ai_agent?
    assert_equal "Stickman", agent.name
    assert_equal "stickman", agent.tenant_users.find_by(tenant_id: @tenant.id).handle
    assert_redirected_to "/ai-agents/stickman"
  end

  test "accept uses the name and handle the principal submitted, not the proposed ones" do
    sign_in_with_ai_agents_reverify(@human)

    accept(name: "Renamed", handle: "renamed-agent")

    agent = reload_signup.ai_agent_user
    assert_equal "Renamed", agent.name
    assert_equal "renamed-agent", agent.tenant_users.find_by(tenant_id: @tenant.id).handle
  end

  test "accept applies the principal's capability and public-write choices and forces external mode" do
    sign_in_with_ai_agents_reverify(@human)
    capability = CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS.first

    accept(capabilities: ["", capability], allow_public_writes: "1", mode: "internal")

    agent = reload_signup.ai_agent_user
    assert_equal [capability], agent.agent_configuration["capabilities"]
    assert_equal true, agent.agent_configuration["allow_public_writes"]
    assert_equal "external", agent.agent_configuration["mode"]
  end

  test "accept with a wrong pairing code creates nothing and counts the attempt" do
    sign_in_with_ai_agents_reverify(@human)
    wrong = @signup.pairing_code == "000000" ? "111111" : "000000"

    assert_no_difference -> { agents_of(@human).count } do
      accept(pairing_code: wrong)
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "pairing code"
    assert_equal 1, reload_signup.failed_pairing_attempts
    assert_equal "pending", reload_signup.state
  end

  test "a wrong pairing code keeps the principal's choices and puts the error at the field" do
    sign_in_with_ai_agents_reverify(@human)
    wrong = @signup.pairing_code == "000000" ? "111111" : "000000"

    accept(pairing_code: wrong, name: "Renamed", identity_prompt: "Be brief.",
           capabilities: ["", "create_note"], allow_public_writes: "1")

    assert_response :unprocessable_entity
    assert_select "input[name=name][value=?]", "Renamed"
    assert_select "textarea[name=identity_prompt]", text: /Be brief\./
    assert_select "input#cap_create_note[checked]"
    assert_select "input#cap_vote[checked]", count: 0
    assert_select "input#allow_public_writes[checked]"
    assert_select "input[name=pairing_code][autofocus]"
    assert_select "#pairing-code-section", text: /does not match/
  end

  test "the claim form starts from the default capability choices" do
    sign_in_with_ai_agents_reverify(@human)

    get claim_path_for

    assert_select "input#cap_create_note[checked]"
    assert_select "input#cap_vote[checked]"
    assert_select "input#allow_public_writes[checked]", count: 0
    assert_select "input[name=pairing_code][autofocus]", count: 0
  end

  test "decline is styled as the secondary choice" do
    sign_in_with_ai_agents_reverify(@human)

    get claim_path_for

    assert_select "form[action=?] button.pulse-action-btn-secondary", "/agent-signups/#{@signup.public_id}/decline"
  end

  test "the fifth wrong pairing code ends the request" do
    sign_in_with_ai_agents_reverify(@human)
    wrong = @signup.pairing_code == "000000" ? "111111" : "000000"

    AgentSignup::MAX_PAIRING_ATTEMPTS.times { accept(pairing_code: wrong) }
    assert reload_signup.expired?

    assert_no_difference -> { agents_of(@human).count } do
      accept
    end
    assert_response :gone
  end

  test "accept by anyone other than the named principal creates nothing" do
    sign_in_with_ai_agents_reverify(other_member)

    assert_no_difference -> { User.where(user_type: "ai_agent").count } do
      accept
    end

    assert_response :forbidden
    assert_equal "pending", reload_signup.state
    assert_equal 0, reload_signup.failed_pairing_attempts
  end

  test "accept re-checks that the principal is still eligible" do
    sign_in_with_ai_agents_reverify(@human)

    AgentSignup.stub(:eligible_principal?, false) do
      assert_no_difference -> { agents_of(@human).count } do
        accept
      end
    end

    assert_response :forbidden
    assert_equal "pending", reload_signup.state
  end

  test "accept requires a name" do
    sign_in_with_ai_agents_reverify(@human)

    assert_no_difference -> { agents_of(@human).count } do
      accept(name: " ")
    end

    assert_response :unprocessable_entity
    assert_equal "pending", reload_signup.state
  end

  test "accept with a taken handle creates nothing and leaves the request open" do
    sign_in_with_ai_agents_reverify(@human)
    accept(start_signup(name: "First", handle: "first-agent"), handle: "shared-handle")
    second = start_signup(name: "Second", handle: "second-agent")

    assert_no_difference -> { agents_of(@human).count } do
      accept(second, handle: "shared-handle")
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "handle"
    assert_equal "pending", reload_signup(second).state
  end

  test "accept a second time does not create a second agent" do
    sign_in_with_ai_agents_reverify(@human)
    accept

    assert_no_difference -> { agents_of(@human).count } do
      accept
    end

    assert_response :conflict
  end

  test "accept sends the principal to billing when billing is not set up, and keeps the request open" do
    enable_stripe_billing_flag!(@tenant)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    existing = create_ai_agent(parent: @human, name: "Existing Billable Agent")
    @tenant.add_user!(existing)
    Tenant.clear_thread_scope
    sign_in_with_ai_agents_reverify(@human)

    assert_no_difference -> { agents_of(@human).count } do
      accept(confirm_billing: "1")
    end

    assert_redirected_to "/billing"
    assert_equal "pending", reload_signup.state
  end

  test "accept requires the billing confirmation when billing is on" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @human, stripe_id: "cus_#{SecureRandom.hex(8)}", active: true)
    sign_in_with_ai_agents_reverify(@human)

    StripeService.stub(:preview_proration, 0) do
      assert_no_difference -> { agents_of(@human).count } do
        accept
      end
    end

    assert_response :unprocessable_entity
    assert_equal "pending", reload_signup.state
  end

  # ---------- decline ----------

  test "decline marks the request declined and creates nothing" do
    sign_in_with_ai_agents_reverify(@human)

    assert_no_difference -> { agents_of(@human).count } do
      post "/agent-signups/#{@signup.public_id}/decline"
    end

    assert_equal "declined", reload_signup.state
    assert_redirected_to "/ai-agents"

    get claim_path_for
    assert_response :gone
    assert_includes response.body, "declined"
  end

  test "decline by anyone other than the named principal changes nothing" do
    sign_in_with_ai_agents_reverify(other_member)

    post "/agent-signups/#{@signup.public_id}/decline"

    assert_response :forbidden
    assert_equal "pending", reload_signup.state
  end

  # ---------- pending requests on /ai-agents ----------

  test "the agents page lists the member's open requests with a link to claim" do
    sign_in_as(@human, tenant: @tenant)

    get "/ai-agents"

    assert_response :success
    assert_select "a[href=?]", claim_path_for
  end

  test "the agents page does not list another member's requests or closed ones" do
    theirs = start_signup(email: other_member.email, name: "Theirs", handle: nil)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @signup.decline!
    Tenant.clear_thread_scope
    sign_in_as(@human, tenant: @tenant)

    get "/ai-agents"

    assert_response :success
    assert_select "a[href=?]", claim_path_for(theirs), count: 0
    assert_select "a[href=?]", claim_path_for, count: 0
  end
  # ---------- the claimed agent's page ----------

  test "the agent's page says the agent has yet to collect their token" do
    sign_in_with_ai_agents_reverify(@human)
    accept

    get "/ai-agents/stickman"

    assert_response :success
    assert_includes response.body, "Waiting for the agent to collect their token"
  end

  test "the agent's page drops the notice once the token is collected" do
    sign_in_with_ai_agents_reverify(@human)
    accept
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    assert reload_signup.pick_up!
    Tenant.clear_thread_scope

    get "/ai-agents/stickman"

    assert_response :success
    assert_not_includes response.body, "Waiting for the agent to collect their token"
    assert_not_includes response.body, "did not collect their token"
  end

  test "the agent's page points to settings when the pickup window lapsed uncollected" do
    sign_in_with_ai_agents_reverify(@human)
    accept

    travel 25.hours do
      sign_in_as(@human, tenant: @tenant)
      get "/ai-agents/stickman"

      assert_response :success
      assert_includes response.body, "did not collect their token"
      assert_select "a[href=?]", "/ai-agents/stickman/settings"
    end
  end

  # ---------- markdown ----------

  MD = { "Accept" => "text/markdown" }.freeze

  test "claim page in markdown shows the request and says to claim in a browser" do
    sign_in_with_ai_agents_reverify(@human)

    get claim_path_for, headers: MD

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_includes response.body, "Stickman"
    assert_includes response.body, "browser"
    assert_not_includes response.body, @signup.pairing_code
  end

  test "claim page in markdown tells any other member the request is not addressed to them" do
    sign_in_with_ai_agents_reverify(other_member)

    get claim_path_for, headers: MD

    assert_response :forbidden
    assert_includes response.body, "not addressed to you"
    assert_not_includes response.body, "Stickman"
  end

  test "accept and decline are browser-only" do
    sign_in_with_ai_agents_reverify(@human)

    assert_no_difference -> { agents_of(@human).count } do
      post claim_path_for, params: { name: "Stickman", pairing_code: @signup.pairing_code }, headers: MD
    end
    assert_response :not_acceptable
    assert_includes response.body, "browser"

    post "/agent-signups/#{@signup.public_id}/decline", headers: MD
    assert_response :not_acceptable
    assert_equal "pending", reload_signup.state
  end

  test "the agents page in markdown lists open requests" do
    sign_in_as(@human, tenant: @tenant)

    get "/ai-agents", headers: MD

    assert_response :success
    assert_includes response.body, claim_path_for
    assert_includes response.body, "Stickman"
  end

  test "the agent's page in markdown carries the pickup notices" do
    sign_in_with_ai_agents_reverify(@human)
    accept

    get "/ai-agents/stickman", headers: MD
    assert_includes response.body, "Waiting for the agent to collect their token"

    travel 25.hours do
      sign_in_as(@human, tenant: @tenant)
      get "/ai-agents/stickman", headers: MD
      assert_includes response.body, "did not collect their token"
    end
  end
end
