# typed: false

require "test_helper"

class SweepStuckLLMUsageRecordsJobTest < ActiveSupport::TestCase
  PRICES = {
    "anthropic/claude-sonnet-4.6" => { input_per_million: "3.90", output_per_million: "19.50" },
  }.freeze

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @agent = create_ai_agent(parent: @user)
    Tenant.clear_thread_scope
  end

  def create_record!(status: "pending", occurred_at: Time.current, model: nil,
                     input_tokens: nil, output_tokens: nil, estimated_cost_cents: nil, completed_at: nil)
    LLMUsageRecord.create!(
      selection_id: "sel_#{SecureRandom.uuid}",
      status: status,
      ai_agent_id: @agent.id,
      payer_stripe_customer_id: "cus_sweep_test",
      origin_tenant_id: @tenant.id,
      model: model,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      estimated_cost_cents: estimated_cost_cents,
      occurred_at: occurred_at,
      completed_at: completed_at,
    )
  end

  test "re-prices a pending row whose tokens landed but could not be priced at report time" do
    record = create_record!(model: "anthropic/claude-sonnet-4.6", input_tokens: 1_000_000, output_tokens: 0,
                            occurred_at: 1.hour.ago)

    GatewayModelCatalog.stub :prices, PRICES do
      SweepStuckLLMUsageRecordsJob.new.perform
    end

    record.reload
    assert_equal "completed", record.status
    assert_equal 390, record.estimated_cost_cents
    assert record.completed_at.present?, "re-pricing should anchor the cost at sweep time"
  end

  test "re-prices even rows older than the abandon threshold when the catalog can price them" do
    record = create_record!(model: "anthropic/claude-sonnet-4.6", input_tokens: 500, output_tokens: 500,
                            occurred_at: 3.days.ago)

    GatewayModelCatalog.stub :prices, PRICES do
      SweepStuckLLMUsageRecordsJob.new.perform
    end

    assert_equal "completed", record.reload.status
  end

  test "abandons an old pending row whose usage never arrived" do
    record = create_record!(occurred_at: 25.hours.ago)

    GatewayModelCatalog.stub :prices, PRICES do
      SweepStuckLLMUsageRecordsJob.new.perform
    end

    record.reload
    assert_equal "abandoned", record.status
    assert_nil record.completed_at
    assert_nil record.estimated_cost_cents
  end

  test "abandons an old pending row with tokens whose model is still unpriceable" do
    record = create_record!(model: "unknown/model", input_tokens: 100, output_tokens: 100,
                            occurred_at: 25.hours.ago)

    GatewayModelCatalog.stub :prices, PRICES do
      SweepStuckLLMUsageRecordsJob.new.perform
    end

    assert_equal "abandoned", record.reload.status
  end

  test "leaves recent pending rows alone" do
    no_usage_yet = create_record!(occurred_at: 5.minutes.ago)
    unpriceable = create_record!(model: "unknown/model", input_tokens: 100, output_tokens: 100,
                                 occurred_at: 2.hours.ago)

    GatewayModelCatalog.stub :prices, PRICES do
      SweepStuckLLMUsageRecordsJob.new.perform
    end

    assert_equal "pending", no_usage_yet.reload.status
    assert_equal "pending", unpriceable.reload.status
  end

  test "leaves terminal rows alone" do
    completed = create_record!(status: "completed", occurred_at: 3.days.ago,
                               estimated_cost_cents: 42, completed_at: 3.days.ago)
    failed = create_record!(status: "failed", occurred_at: 3.days.ago, completed_at: 3.days.ago)

    GatewayModelCatalog.stub :prices, PRICES do
      SweepStuckLLMUsageRecordsJob.new.perform
    end

    assert_equal "completed", completed.reload.status
    assert_equal "failed", failed.reload.status
    assert_equal 42, completed.reload.estimated_cost_cents
  end

  test "is on the sidekiq-cron schedule" do
    entry = SIDEKIQ_CRON_SCHEDULE["sweep_stuck_llm_usage_records"]
    assert entry, "sweep_stuck_llm_usage_records is missing from the sidekiq-cron schedule"
    assert_equal "SweepStuckLLMUsageRecordsJob", entry["class"]
  end
end
