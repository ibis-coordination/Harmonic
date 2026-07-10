require "test_helper"

class ApiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user
    @internal_context = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: AutomationRule.create!(
        tenant: @tenant,
        collective: @collective,
        name: "Auth test rule",
        trigger_type: "manual",
        trigger_config: {},
        actions: [],
        created_by: @user
      ),
      trigger_source: "manual",
      status: "pending"
    )
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes
    )
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def v1_api_base_path
    "#{@collective.path}/api/v1"
  end

  def v1_api_endpoint
    "#{v1_api_base_path}/cycles"
  end

  test "allows access with valid API token" do
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  test "denies access with invalid API token" do
    @headers["Authorization"] = "Bearer invalid_token"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access without API token" do
    @headers.delete("Authorization")
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access with expired API token" do
    @api_token.update!(expires_at: 1.day.ago)
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access with deleted API token" do
    @api_token.update!(deleted_at: Time.current)
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "v1 API does not accept POST writes regardless of scope (read-only API)" do
    @api_token.update!(scopes: ApiToken.valid_scopes)
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    assert_raises(ActionController::RoutingError) do
      post "#{v1_api_base_path}/notes", params: { title: "x" }.to_json, headers: @headers
    end
  end

  # === API Enabled/Disabled Tests ===

  test "denies access when API is disabled at tenant level" do
    @tenant.set_feature_flag!("api", false)

    get v1_api_endpoint, headers: @headers
    assert_response :forbidden
    assert_match(/API not enabled/, JSON.parse(response.body)["error"])
  end

  test "denies access when API is disabled at collective level" do
    # Create a non-main collective since main collectives always have API enabled
    non_main_collective = Collective.create!(
      name: "Test Collective",
      handle: "test-collective-#{SecureRandom.hex(4)}",
      tenant: @tenant,
      created_by: @user,
      updated_by: @user
    )
    non_main_collective.enable_api!

    # Use the non-main collective's API endpoint
    non_main_api_endpoint = "#{non_main_collective.path}/api/v1/cycles"

    # Verify it works when enabled
    get non_main_api_endpoint, headers: @headers
    assert_response :success

    # Now disable and verify it fails
    non_main_collective.settings["api_enabled"] = false
    non_main_collective.settings["feature_flags"] = { "api" => false }
    non_main_collective.save!

    get non_main_api_endpoint, headers: @headers
    assert_response :forbidden
    assert_match(/API not enabled/, JSON.parse(response.body)["error"])
  end

  test "allows access when API is re-enabled" do
    # Disable then re-enable
    @tenant.settings["api_enabled"] = false
    @tenant.save!
    @tenant.enable_api!

    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  # === Internal Token Bypass Tests ===

  test "internal token bypasses collective-level API check" do
    # Create a non-main collective with API disabled
    non_main_collective = Collective.create!(
      name: "Internal Test Collective",
      handle: "internal-test-#{SecureRandom.hex(4)}",
      tenant: @tenant,
      created_by: @user,
      updated_by: @user
    )
    # Ensure API is disabled
    non_main_collective.settings["api_enabled"] = false
    non_main_collective.settings["feature_flags"] = { "api" => false }
    non_main_collective.save!

    # Create internal token
    internal_token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @internal_context)
    internal_headers = {
      "Authorization" => "Bearer #{internal_token.plaintext_token}",
      "Content-Type" => "application/json",
    }

    # Internal token should bypass the collective API check
    non_main_api_endpoint = "#{non_main_collective.path}/api/v1/cycles"
    get non_main_api_endpoint, headers: internal_headers
    assert_response :success
  end

  test "internal token bypasses tenant-level API check" do
    # Disable API at tenant level
    @tenant.set_feature_flag!("api", false)

    # Create internal token
    internal_token = ApiToken.create_internal_token(user: @user, tenant: @tenant, context: @internal_context)
    internal_headers = {
      "Authorization" => "Bearer #{internal_token.plaintext_token}",
      "Content-Type" => "application/json",
    }

    # Internal token should bypass the tenant API check
    get v1_api_endpoint, headers: internal_headers
    assert_response :success
  end

  test "external token still blocked when API disabled" do
    # Disable API at tenant level
    @tenant.set_feature_flag!("api", false)

    # External token should still be blocked
    get v1_api_endpoint, headers: @headers
    assert_response :forbidden
    assert_match(/API not enabled/, JSON.parse(response.body)["error"])
  end

  # === Token Scope Edge Cases ===

  test "token with empty scopes cannot be created" do
    assert_raises ActiveRecord::RecordInvalid do
      ApiToken.create!(
        tenant: @tenant,
        user: @user,
        scopes: []
      )
    end
  end

  test "token with invalid scopes cannot be created" do
    assert_raises ActiveRecord::RecordInvalid do
      @api_token.update!(scopes: ["READ:all"]) # Wrong case
    end
  end

  # === Multiple Token Tests ===

  test "user can have multiple active tokens" do
    token2 = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes
    )
    token2_plaintext = token2.plaintext_token

    # Both tokens should work
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :success

    @headers["Authorization"] = "Bearer #{token2_plaintext}"
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  # === Billing-gated API access for human-owned tokens ===

  test "human-owned token returns 403 billing_required when stripe_billing is on and user has no subscription" do
    enable_stripe_billing_flag!(@tenant)
    # @user owns @api_token; counts_self_for_api_access? is now true → billable_quantity > 0 → setup false.

    get v1_api_endpoint, headers: @headers

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "billing_required", body["error"]
    assert_match(/billing/i, body["message"].to_s)
  end

  test "human-owned token works when user has an active stripe subscription" do
    enable_stripe_billing_flag!(@tenant)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_api_active_#{SecureRandom.hex(4)}", active: true)

    get v1_api_endpoint, headers: @headers

    assert_response :success
  end

  test "human-owned token works when stripe_billing is disabled on the tenant" do
    # Sanity check: no billing flag → no gate.
    get v1_api_endpoint, headers: @headers

    assert_response :success
  end

  test "ai-agent-owned token is NOT gated by parent's personal billing state" do
    enable_stripe_billing_flag!(@tenant)
    # Parent has unmet billing, but the AGENT's own token should still work —
    # the agent itself is billed via the agent's pending_billing_setup pattern,
    # which is enforced at agent creation, not on each API call.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent = create_ai_agent(parent: @user, name: "Authzed Agent #{SecureRandom.hex(4)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    agent_token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes)
    Tenant.clear_thread_scope
    agent_headers = {
      "Authorization" => "Bearer #{agent_token.plaintext_token}",
      "Content-Type" => "application/json",
    }

    get v1_api_endpoint, headers: agent_headers

    assert_response :success
  end

  test "sys_admin's human token bypasses the billing gate (admins are exempt)" do
    enable_stripe_billing_flag!(@tenant)
    @user.update!(sys_admin: true)

    get v1_api_endpoint, headers: @headers

    assert_response :success
  end

  # === Activation-gated API access ===

  test "human-owned token returns 403 activation_required when the user is not fully activated" do
    # Unverify @user's email (test_helper marks it verified by default).
    @user.omni_auth_identity.update!(email_confirmed_at: nil)

    get v1_api_endpoint, headers: @headers

    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "activation_required", body["error"]
    assert_match(/activate/i, body["message"].to_s)
  end

  test "agent-owned token returns 403 activation_required when the agent's PARENT is not fully activated" do
    # Closes the loophole: half-activated parent spawns an agent and uses the
    # agent's token to bypass the activation gate. The agent's parent's state
    # is what matters for agent-owned tokens.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent = create_ai_agent(parent: @user, name: "Unactivated Parent Agent #{SecureRandom.hex(4)}", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    agent_token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes)
    Tenant.clear_thread_scope

    @user.omni_auth_identity.update!(email_confirmed_at: nil)  # parent unactivated

    get v1_api_endpoint, headers: {
      "Authorization" => "Bearer #{agent_token.plaintext_token}",
      "Content-Type" => "application/json",
    }
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "activation_required", body["error"]
  end

  test "internal tokens are exempt from the activation gate" do
    # Internal (runner-issued) tokens are system-managed and used by background
    # jobs that don't have a user-facing activation flow.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    agent = create_ai_agent(parent: @user, name: "Internal Token Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    internal_token = ApiToken.create_internal_token(user: agent, tenant: @tenant, context: @internal_context)
    Tenant.clear_thread_scope

    @user.omni_auth_identity.update!(email_confirmed_at: nil)  # parent unactivated

    get v1_api_endpoint, headers: {
      "Authorization" => "Bearer #{internal_token.plaintext_token}",
      "Content-Type" => "application/json",
    }
    assert_response :success
  end

  test "deleting one token does not affect other tokens" do
    token2 = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes
    )
    token2_plaintext = token2.plaintext_token

    # Delete the first token
    @api_token.update!(deleted_at: Time.current)

    # First token should fail
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized

    # Second token should still work
    @headers["Authorization"] = "Bearer #{token2_plaintext}"
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
