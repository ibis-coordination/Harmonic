# typed: false

require "test_helper"

class Internal::LLMGatewayControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("internal_ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = create_ai_agent(parent: @user)
    @billing_customer = StripeCustomer.create!(
      billable: @ai_agent,
      stripe_id: "cus_test123",
      active: true,
      pricing_plan_subscription_id: "bpps_test123"
    )
    # A funded, billed task run (stamped with the customer, as dispatch does).
    @task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "running",
      stripe_customer_id: @billing_customer.id
    )
    # A task run that was never stamped with a billing customer.
    @unbilled_task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Unbilled task",
      max_steps: 10,
      status: "running"
    )

    @previous_secret = ENV.fetch("AGENT_RUNNER_SECRET", nil)
    @secret = "test-secret-for-hmac"
    ENV["AGENT_RUNNER_SECRET"] = @secret

    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", "harmonic.local")}"
  end

  teardown do
    if @previous_secret.nil?
      ENV.delete("AGENT_RUNNER_SECRET")
    else
      ENV["AGENT_RUNNER_SECRET"] = @previous_secret
    end
  end

  test "returns the payer customer id for a funded billed task" do
    # The credit balance is not consulted here (enforced at dispatch + the
    # relay's 402), so a live balance call must never happen on this path.
    StripeService.stub :get_credit_balance, ->(_) { raise "must not fetch balance on the select-payer path" } do
      select_payer(task_run_id: @task_run.id, model: "anthropic/claude-sonnet-4.6")
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "cus_test123", body["payer_customer_id"]
  end

  test "returns 402 not_funded when there is no pricing plan subscription" do
    @billing_customer.update!(pricing_plan_subscription_id: nil)

    select_payer(task_run_id: @task_run.id)

    assert_response :payment_required
    assert_equal "not_funded", JSON.parse(response.body)["error"]
  end

  test "does not resolve a task run belonging to another tenant" do
    other_tenant = create_tenant(subdomain: "other", name: "Other Tenant")
    other_user = create_user
    other_tenant.add_user!(other_user)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, handle: "other-collective")
    other_collective.add_user!(other_user)
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)
    other_agent = create_ai_agent(parent: other_user)
    other_customer = StripeCustomer.create!(
      billable: other_agent,
      stripe_id: "cus_other",
      active: true,
      pricing_plan_subscription_id: "bpps_other"
    )
    other_task_run = AiAgentTaskRun.create!(
      tenant: other_tenant,
      ai_agent: other_agent,
      initiated_by: other_user,
      task: "Other tenant task",
      max_steps: 10,
      status: "running",
      stripe_customer_id: other_customer.id
    )
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    # The request arrives on @tenant's subdomain (set in setup) but references
    # the other tenant's task run — it must not be resolvable.
    select_payer(task_run_id: other_task_run.id)
    assert_response :not_found
  end

  test "returns 422 not_a_billed_task when the task run has no billing customer" do
    select_payer(task_run_id: @unbilled_task_run.id)

    assert_response :unprocessable_entity
    assert_equal "not_a_billed_task", JSON.parse(response.body)["error"]
  end

  test "returns 404 when the task run does not exist" do
    select_payer(task_run_id: "does-not-exist")
    assert_response :not_found
  end

  test "returns a pool customer for a pool-funded agent" do
    attach_funding_collective!(@ai_agent, ["cus_pool_a", "cus_pool_b"])

    # The unbilled run has no stamped customer — the pool alone funds it.
    select_payer(task_run_id: @unbilled_task_run.id, model: "anthropic/claude-sonnet-4.6")

    assert_response :success
    assert_includes ["cus_pool_a", "cus_pool_b"], JSON.parse(response.body)["payer_customer_id"]
  end

  test "rejects an unsigned request" do
    post "/internal/llm-gateway/select-payer",
         params: { task_run_id: @task_run.id }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  # === select-payer-for-token (external gateway ingress) ===
  # These requests arrive via the public llm.<hostname> edge, so the gateway
  # cannot know a tenant subdomain — the token itself carries the tenant.
  # All error bodies are OpenAI-shaped ({error: {message, type, code}})
  # because the gateway passes them through to the external client verbatim.

  def create_gateway_agent_and_token(token_type: "llm_gateway")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    agent = create_ai_agent(parent: @user, agent_configuration: { "mode" => "external" })
    token = ApiToken.create!(
      tenant: @tenant, user: agent, name: "Gateway key", scopes: ["read:all"], token_type: token_type
    )
    [agent, token]
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  # Fund the agent through an agent_funding collective. The first stripe id
  # funds @user (the agent's principal, who must be a member); each further id
  # funds an additional member.
  def attach_funding_collective!(agent, stripe_ids)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    funding = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Agent Funding",
      handle: "fund-#{SecureRandom.hex(4)}",
      collective_type: "agent_funding"
    )
    funding.add_user!(@user)
    stripe_ids.each_with_index do |stripe_id, index|
      member = @user
      if index.positive?
        member = create_user
        @tenant.add_user!(member)
        funding.add_user!(member)
      end
      StripeCustomer.create!(
        billable: member, stripe_id: stripe_id, active: true, pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}"
      )
    end
    agent.update!(funding_collective: funding)
    funding
  ensure
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def select_payer_for_token(body_hash)
    # Host is deliberately NOT a tenant subdomain: the action must not depend
    # on subdomain tenant resolution.
    host! "app.#{ENV.fetch("HOSTNAME", "harmonic.local")}"
    body = body_hash.to_json
    post "/internal/llm-gateway/select-payer-for-token", params: body, headers: signed_headers(body)
  end

  def assert_openai_error(code)
    error = JSON.parse(response.body)["error"]
    assert error.is_a?(Hash), "expected an OpenAI-shaped error body, got #{response.body}"
    assert_equal code, error["code"]
    assert error["message"].present?
    assert error["type"].present?
  end

  test "token caller: returns a pool payer and the mapped model" do
    @tenant.enable_feature_flag!("llm_gateway")
    agent, token = create_gateway_agent_and_token
    attach_funding_collective!(agent, ["cus_pool_a", "cus_pool_b"])

    select_payer_for_token(agent_token: token.plaintext_token, model: "anthropic/claude-sonnet-4.6")

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes ["cus_pool_a", "cus_pool_b"], body["payer_customer_id"]
    assert_equal "anthropic/claude-sonnet-4.6", body["model"]
    assert_not_nil token.reload.last_used_at, "expected last_used_at to be bumped"
  end

  test "token caller: falls back to the agent's billing customer" do
    @tenant.enable_feature_flag!("llm_gateway")
    agent, token = create_gateway_agent_and_token
    customer = StripeCustomer.create!(
      billable: agent, stripe_id: "cus_external_agent", active: true, pricing_plan_subscription_id: "bpps_ext"
    )
    agent.update!(stripe_customer_id: customer.id)

    select_payer_for_token(agent_token: token.plaintext_token, model: "anthropic/claude-sonnet-4.6")

    assert_response :success
    assert_equal "cus_external_agent", JSON.parse(response.body)["payer_customer_id"]
  end

  test "token caller: blank model maps to the default model" do
    @tenant.enable_feature_flag!("llm_gateway")
    agent, token = create_gateway_agent_and_token
    attach_funding_collective!(agent, ["cus_pool_a"])

    select_payer_for_token(agent_token: token.plaintext_token)

    assert_response :success
    assert_equal StripeGatewayModelMapper::DEFAULT_MODEL, JSON.parse(response.body)["model"]
  end

  test "token caller: 401 for a missing token" do
    select_payer_for_token(model: "anthropic/claude-sonnet-4.6")
    assert_response :unauthorized
    assert_openai_error("invalid_token")
  end

  test "token caller: 401 for an unknown token" do
    select_payer_for_token(agent_token: "not-a-real-token")
    assert_response :unauthorized
    assert_openai_error("invalid_token")
  end

  test "token caller: 401 for a revoked token" do
    @tenant.enable_feature_flag!("llm_gateway")
    _agent, token = create_gateway_agent_and_token
    plaintext = token.plaintext_token
    token.delete!

    select_payer_for_token(agent_token: plaintext)
    assert_response :unauthorized
    assert_openai_error("invalid_token")
  end

  test "token caller: 401 for an expired token" do
    @tenant.enable_feature_flag!("llm_gateway")
    _agent, token = create_gateway_agent_and_token
    token.update_column(:expires_at, 1.hour.ago)

    select_payer_for_token(agent_token: token.plaintext_token)
    assert_response :unauthorized
    assert_openai_error("invalid_token")
  end

  test "token caller: 401 for a rest-type token" do
    @tenant.enable_feature_flag!("llm_gateway")
    _agent, token = create_gateway_agent_and_token(token_type: "rest")

    select_payer_for_token(agent_token: token.plaintext_token)
    assert_response :unauthorized
    assert_openai_error("invalid_token")
  end

  test "token caller: 403 when the tenant flag is off" do
    agent, token = create_gateway_agent_and_token
    attach_funding_collective!(agent, ["cus_pool_a"])

    select_payer_for_token(agent_token: token.plaintext_token)

    assert_response :forbidden
    assert_openai_error("feature_disabled")
  end

  test "token caller: 402 when the agent is not funded" do
    @tenant.enable_feature_flag!("llm_gateway")
    _agent, token = create_gateway_agent_and_token

    select_payer_for_token(agent_token: token.plaintext_token)
    assert_response :payment_required
    assert_openai_error("not_funded")
  end

  test "token caller: 400 for a model the gateway cannot proxy" do
    @tenant.enable_feature_flag!("llm_gateway")
    agent, token = create_gateway_agent_and_token
    attach_funding_collective!(agent, ["cus_pool_a"])

    select_payer_for_token(agent_token: token.plaintext_token, model: "local-ollama-model")

    assert_response :bad_request
    assert_openai_error("unsupported_model")
  end

  test "token caller: rejects an unsigned request" do
    host! "app.#{ENV.fetch("HOSTNAME", "harmonic.local")}"
    post "/internal/llm-gateway/select-payer-for-token",
         params: { agent_token: "anything" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  private

  # === Usage ledger (selection opens a record, record-usage completes it) ===

  test "select-payer opens a pending usage record and returns its selection id" do
    select_payer(task_run_id: @task_run.id)

    assert_response :success
    selection_id = JSON.parse(response.body)["selection_id"]
    assert selection_id.present?, "expected select-payer to return a selection_id"
    record = LLMUsageRecord.find_by(selection_id: selection_id)
    assert record.present?, "expected a usage record keyed by the selection id"
    assert_equal "pending", record.status
    assert_equal @ai_agent.id, record.ai_agent_id
    assert_equal "cus_test123", record.payer_stripe_customer_id
    assert_equal @task_run.id, record.ai_agent_task_run_id
    assert_equal @tenant.id, record.origin_tenant_id
    assert record.occurred_at.present?
    assert_nil record.funding_collective_id, "an individual billing draw must not be attributed to a pool"
  end

  test "a pool draw stamps the funding collective on the usage record" do
    funding = attach_funding_collective!(@ai_agent, ["cus_pool_a"])

    select_payer(task_run_id: @unbilled_task_run.id)

    assert_response :success
    selection_id = JSON.parse(response.body)["selection_id"]
    record = LLMUsageRecord.find_by!(selection_id: selection_id)
    assert_equal funding.id, record.funding_collective_id
    assert_equal "cus_pool_a", record.payer_stripe_customer_id
  end

  test "a failed payer resolution opens no usage record" do
    select_payer(task_run_id: @unbilled_task_run.id)

    assert_response :unprocessable_entity
    assert_equal 0, LLMUsageRecord.count
  end

  test "token caller: selection opens a pending usage record with the mapped model" do
    @tenant.enable_feature_flag!("llm_gateway")
    agent, token = create_gateway_agent_and_token
    funding = attach_funding_collective!(agent, ["cus_pool_a"])

    select_payer_for_token(agent_token: token.plaintext_token, model: "anthropic/claude-sonnet-4.6")

    assert_response :success
    selection_id = JSON.parse(response.body)["selection_id"]
    assert selection_id.present?
    record = LLMUsageRecord.find_by(selection_id: selection_id)
    assert record.present?
    assert_equal "pending", record.status
    assert_equal agent.id, record.ai_agent_id
    assert_equal "cus_pool_a", record.payer_stripe_customer_id
    assert_equal "anthropic/claude-sonnet-4.6", record.model
    assert_equal token.id, record.api_token_id
    assert_equal funding.id, record.funding_collective_id
  end

  test "record-usage completes the pending record with tokens and estimated cost" do
    select_payer(task_run_id: @task_run.id)
    selection_id = JSON.parse(response.body)["selection_id"]

    prices = { "anthropic/claude-sonnet-4.6" => { input_per_million: "3.00", output_per_million: "15.00" } }
    GatewayModelCatalog.stub :prices, prices do
      record_usage(selection_id: selection_id, model: "anthropic/claude-sonnet-4.6",
                   input_tokens: 812, output_tokens: 344, status: "ok")
    end

    assert_response :success
    record = LLMUsageRecord.find_by!(selection_id: selection_id)
    assert_equal "completed", record.status
    assert_equal 812, record.input_tokens
    assert_equal 344, record.output_tokens
    assert_equal "anthropic/claude-sonnet-4.6", record.model
    # (812 × $3.00 + 344 × $15.00) / 1M tokens = $0.007596 → 0.7596¢
    assert_in_delta 0.7596, record.estimated_cost_cents.to_f, 0.0001
  end

  test "record-usage is idempotent on the selection id" do
    select_payer(task_run_id: @task_run.id)
    selection_id = JSON.parse(response.body)["selection_id"]
    record_usage(selection_id: selection_id, input_tokens: 10, output_tokens: 20, status: "ok")

    record_usage(selection_id: selection_id, input_tokens: 999, output_tokens: 999, status: "ok")

    assert_response :success
    record = LLMUsageRecord.find_by!(selection_id: selection_id)
    assert_equal 10, record.input_tokens, "a replay must not overwrite the recorded usage"
  end

  test "record-usage with an unknown selection id is a 404" do
    record_usage(selection_id: "sel_does_not_exist", input_tokens: 1, output_tokens: 1, status: "ok")

    assert_response :not_found
  end

  test "an upstream error is recorded as failed" do
    select_payer(task_run_id: @task_run.id)
    selection_id = JSON.parse(response.body)["selection_id"]

    record_usage(selection_id: selection_id, input_tokens: 0, output_tokens: 0, status: "error")

    assert_response :success
    assert_equal "failed", LLMUsageRecord.find_by!(selection_id: selection_id).status
  end

  test "an unpriced model completes with no cost estimate" do
    select_payer(task_run_id: @task_run.id)
    selection_id = JSON.parse(response.body)["selection_id"]

    GatewayModelCatalog.stub :prices, {} do
      record_usage(selection_id: selection_id, model: "unknown/model", input_tokens: 5, output_tokens: 5, status: "ok")
    end

    assert_response :success
    record = LLMUsageRecord.find_by!(selection_id: selection_id)
    assert_equal "completed", record.status
    assert_nil record.estimated_cost_cents
  end

  def record_usage(body_hash)
    body = body_hash.to_json
    post "/internal/llm-gateway/record-usage", params: body, headers: signed_headers(body)
  end

  def select_payer(body_hash)
    body = body_hash.to_json
    post "/internal/llm-gateway/select-payer", params: body, headers: signed_headers(body)
  end

  def signed_headers(body)
    timestamp = Time.current.to_i.to_s
    nonce = SecureRandom.uuid
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("sha256", @secret, "#{nonce}.#{timestamp}.#{body}")
    {
      "Content-Type" => "application/json",
      "X-Internal-Signature" => signature,
      "X-Internal-Timestamp" => timestamp,
      "X-Internal-Nonce" => nonce,
    }
  end
end
