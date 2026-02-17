# typed: true

# Service for testing automations with synthetic data.
# Executes the automation synchronously and returns detailed results.
class AutomationTestService
  extend T::Sig

  class Result < T::Struct
    const :success, T::Boolean
    const :run, T.nilable(AutomationRuleRun)
    const :error, T.nilable(String)
    const :actions_executed, T::Array[T::Hash[String, T.untyped]], default: []

    def success?
      success
    end
  end

  # Test an automation rule with synthetic data appropriate for its trigger type.
  # For event triggers, builds a synthetic event.
  # For schedule triggers, executes with current timestamp.
  # For webhook triggers, builds synthetic webhook payload.
  # For manual triggers, uses provided or default inputs.
  #
  # @param rule [AutomationRule] The automation rule to test
  # @param inputs [Hash] Optional inputs for manual triggers
  # @param dry_run [Boolean] If true, validates without side effects (not yet implemented)
  # @return [Result] The test result with execution details
  sig do
    params(
      rule: AutomationRule,
      inputs: T::Hash[String, T.untyped],
      dry_run: T::Boolean
    ).returns(Result)
  end
  def self.test!(rule, inputs: {}, dry_run: false)
    new(rule, inputs: inputs, dry_run: dry_run).test!
  end

  sig do
    params(
      rule: AutomationRule,
      inputs: T::Hash[String, T.untyped],
      dry_run: T::Boolean
    ).void
  end
  def initialize(rule, inputs: {}, dry_run: false)
    @rule = rule
    @inputs = inputs
    @dry_run = dry_run
  end

  sig { returns(Result) }
  def test!
    # Build test context based on trigger type
    test_event = build_test_event
    trigger_data = build_trigger_data

    # Create a run record with 'test' source
    run = AutomationRuleRun.create!(
      tenant: @rule.tenant,
      collective: @rule.collective,
      automation_rule: @rule,
      triggered_by_event: test_event,
      trigger_source: "test",
      trigger_data: trigger_data,
      status: "pending",
    )

    # Execute synchronously
    AutomationExecutor.execute(run)

    # For test runs, deliver webhooks synchronously so user gets immediate feedback
    deliver_pending_webhooks_synchronously(run)

    run.reload
    Result.new(
      success: run.completed?,
      run: run,
      error: run.error_message,
      actions_executed: run.actions_executed || [],
    )
  rescue StandardError => e
    Result.new(
      success: false,
      run: nil,
      error: e.message,
      actions_executed: [],
    )
  end

  private

  # Deliver any pending webhooks synchronously for immediate test feedback
  sig { params(run: AutomationRuleRun).void }
  def deliver_pending_webhooks_synchronously(run)
    run.webhook_deliveries.where(status: "pending").find_each do |delivery|
      WebhookDeliveryService.deliver!(delivery)
    end

    # Update run status based on completed actions
    run.update_status_from_actions! if run.running?
  end

  sig { returns(T.nilable(Event)) }
  def build_test_event
    return nil unless @rule.trigger_type == "event"

    # Create a synthetic test event
    # Use a dedicated test event type to make it clear this is not a real event
    # Store the simulated event type in metadata for reference
    Event.create!(
      tenant: @rule.tenant,
      collective: @rule.collective,
      event_type: "automation_rule.tested",
      actor: @rule.created_by,
      metadata: {
        "test" => true,
        "automation_test" => true,
        "simulated_event_type" => @rule.event_type,
        "automation_rule_id" => @rule.id,
      },
    )
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_trigger_data
    case @rule.trigger_type
    when "event"
      { "test" => true }
    when "schedule"
      {
        "test" => true,
        "scheduled_time" => Time.current.iso8601,
        "cron" => @rule.cron_expression,
      }
    when "webhook"
      build_test_webhook_payload
    when "manual"
      build_manual_inputs
    else
      {}
    end
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_test_webhook_payload
    {
      "test" => true,
      "webhook" => {
        "body" => {
          "example_field" => "test_value",
          "timestamp" => Time.current.iso8601,
        },
        "headers" => {
          "Content-Type" => "application/json",
        },
      },
    }
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_manual_inputs
    # Merge default inputs from trigger config with provided inputs
    defaults = {}
    @rule.manual_inputs.each do |name, definition|
      defaults[name] = definition["default"] if definition.is_a?(Hash) && definition["default"].present?
    end

    {
      "test" => true,
      "inputs" => defaults.merge(@inputs),
    }
  end
end
