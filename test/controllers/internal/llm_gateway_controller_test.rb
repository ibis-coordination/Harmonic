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

  test "rejects an unsigned request" do
    post "/internal/llm-gateway/select-payer",
         params: { task_run_id: @task_run.id }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  private

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
