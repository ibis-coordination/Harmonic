# typed: false

require "test_helper"

class AutomationSchedulerJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @superagent, @user = create_tenant_studio_user
    @tenant.set_feature_flag!("ai_agents", true)
    @ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(@ai_agent)

    # Clear tenant context since this is a system job
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope
  end

  teardown do
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === Basic Scheduling ===

  test "creates run for rule whose cron matches current time" do
    # Create a rule that runs every minute (should always match)
    rule = create_scheduled_rule(cron: "* * * * *")

    assert_difference "AutomationRuleRun.count", 1 do
      AutomationSchedulerJob.perform_now
    end

    run = AutomationRuleRun.unscoped_for_system_job.order(:created_at).last
    assert_equal rule.id, run.automation_rule_id
    assert_equal "schedule", run.trigger_source
    assert_equal "pending", run.status
  end

  test "does not create run for rule whose cron does not match" do
    # Create a rule that runs at a specific time that is not now
    # Use a time that definitely won't match (e.g., 3am on Feb 30th - impossible date)
    # Actually, let's use a specific hour that won't match
    current_hour = Time.current.hour
    non_matching_hour = (current_hour + 12) % 24

    rule = create_scheduled_rule(cron: "0 #{non_matching_hour} * * *")

    assert_no_difference "AutomationRuleRun.count" do
      AutomationSchedulerJob.perform_now
    end
  end

  test "queues execution job for matching rules" do
    rule = create_scheduled_rule(cron: "* * * * *")

    assert_enqueued_with(job: AutomationRuleExecutionJob) do
      AutomationSchedulerJob.perform_now
    end
  end

  test "does not process disabled rules" do
    rule = create_scheduled_rule(cron: "* * * * *", enabled: false)

    assert_no_difference "AutomationRuleRun.count" do
      AutomationSchedulerJob.perform_now
    end
  end

  # === Cron Expression Matching (Time-Frozen Tests) ===

  test "fires rule at exact cron time" do
    rule = create_scheduled_rule(cron: "0 9 * * *") # 9:00am daily

    # At exactly 9:00am, should fire
    travel_to Time.zone.parse("2024-06-15 09:00:00 UTC") do
      assert_difference "AutomationRuleRun.count", 1 do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "does not fire rule one minute before cron time" do
    rule = create_scheduled_rule(cron: "0 9 * * *") # 9:00am daily

    # At 8:59am, should NOT fire
    travel_to Time.zone.parse("2024-06-15 08:59:00 UTC") do
      assert_no_difference "AutomationRuleRun.count" do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "does not fire rule one minute after cron time" do
    rule = create_scheduled_rule(cron: "0 9 * * *") # 9:00am daily

    # At 9:01am, should NOT fire
    travel_to Time.zone.parse("2024-06-15 09:01:00 UTC") do
      assert_no_difference "AutomationRuleRun.count" do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "fires rule with day-of-week constraint on correct day" do
    rule = create_scheduled_rule(cron: "0 9 * * 1") # 9am on Mondays

    # Monday June 17, 2024 at 9:00am
    travel_to Time.zone.parse("2024-06-17 09:00:00 UTC") do
      assert_difference "AutomationRuleRun.count", 1 do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "does not fire day-of-week rule on wrong day" do
    rule = create_scheduled_rule(cron: "0 9 * * 1") # 9am on Mondays

    # Tuesday June 18, 2024 at 9:00am
    travel_to Time.zone.parse("2024-06-18 09:00:00 UTC") do
      assert_no_difference "AutomationRuleRun.count" do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "fires rule with specific day of month" do
    rule = create_scheduled_rule(cron: "0 12 15 * *") # Noon on the 15th

    # June 15, 2024 at noon
    travel_to Time.zone.parse("2024-06-15 12:00:00 UTC") do
      assert_difference "AutomationRuleRun.count", 1 do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "does not fire day-of-month rule on wrong day" do
    rule = create_scheduled_rule(cron: "0 12 15 * *") # Noon on the 15th

    # June 14, 2024 at noon
    travel_to Time.zone.parse("2024-06-14 12:00:00 UTC") do
      assert_no_difference "AutomationRuleRun.count" do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  # === Timezone Handling ===

  test "fires rule in configured timezone at correct local time" do
    # 9am in New York (EST is UTC-5, EDT is UTC-4)
    rule = create_scheduled_rule(cron: "0 9 * * *", timezone: "America/New_York")

    # June 15, 2024 is during EDT (UTC-4), so 9am ET = 1pm UTC
    travel_to Time.zone.parse("2024-06-15 13:00:00 UTC") do
      assert_difference "AutomationRuleRun.count", 1 do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "does not fire timezone rule at wrong UTC time" do
    rule = create_scheduled_rule(cron: "0 9 * * *", timezone: "America/New_York")

    # 9am UTC is NOT 9am in New York
    travel_to Time.zone.parse("2024-06-15 09:00:00 UTC") do
      assert_no_difference "AutomationRuleRun.count" do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  test "handles timezone across date boundary" do
    # 2am in Tokyo (UTC+9), so midnight UTC is 9am Tokyo
    rule = create_scheduled_rule(cron: "0 9 * * *", timezone: "Asia/Tokyo")

    # June 15 at midnight UTC = June 15 at 9am Tokyo
    travel_to Time.zone.parse("2024-06-15 00:00:00 UTC") do
      assert_difference "AutomationRuleRun.count", 1 do
        AutomationSchedulerJob.perform_now
      end
    end
  end

  # === Full Integration Flow ===

  test "full flow: scheduled rule triggers and completes execution at cron time" do
    rule = create_scheduled_rule(cron: "0 9 * * *")

    travel_to Time.zone.parse("2024-06-15 09:00:00 UTC") do
      # Scheduler creates run and queues execution job
      assert_enqueued_with(job: AutomationRuleExecutionJob) do
        AutomationSchedulerJob.perform_now
      end

      # Execute the queued job
      perform_enqueued_jobs

      # Verify the run completed successfully
      run = AutomationRuleRun.unscoped_for_system_job.order(:created_at).last
      assert_equal rule.id, run.automation_rule_id
      assert_equal "completed", run.status
      assert_not_nil run.completed_at
    end
  end

  test "full flow: scheduled webhook rule sends HTTP request at cron time" do
    stub_request(:post, "https://example.com/notify")
      .to_return(status: 200, body: '{"ok": true}')

    rule = AutomationRule.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @user,
      name: "Scheduled Webhook",
      trigger_type: "schedule",
      trigger_config: { "cron" => "0 14 * * *", "timezone" => "UTC" },
      actions: [{ "type" => "webhook", "url" => "https://example.com/notify", "body" => { "scheduled" => true } }],
      enabled: true
    )

    travel_to Time.zone.parse("2024-06-15 14:00:00 UTC") do
      AutomationSchedulerJob.perform_now
      perform_enqueued_jobs

      # Verify webhook was called
      assert_requested(:post, "https://example.com/notify") do |req|
        body = JSON.parse(req.body)
        body["scheduled"] == true
      end

      # Verify run completed
      run = AutomationRuleRun.unscoped_for_system_job.order(:created_at).last
      assert_equal "completed", run.status
    end
  end

  # === Duplicate Prevention ===

  test "does not create duplicate run if rule already ran this minute" do
    rule = create_scheduled_rule(cron: "* * * * *")

    # First run should create a run
    assert_difference "AutomationRuleRun.count", 1 do
      AutomationSchedulerJob.perform_now
    end

    # Second run within the same minute should not create another
    assert_no_difference "AutomationRuleRun.count" do
      AutomationSchedulerJob.perform_now
    end
  end

  test "creates new run after a minute has passed" do
    rule = create_scheduled_rule(cron: "* * * * *")

    # First run
    AutomationSchedulerJob.perform_now
    first_run = AutomationRuleRun.unscoped_for_system_job.order(:created_at).last

    # Simulate time passing by updating last_executed_at to 2 minutes ago
    rule.update!(last_executed_at: 2.minutes.ago)

    # Second run should create a new run
    assert_difference "AutomationRuleRun.unscoped_for_system_job.count", 1 do
      AutomationSchedulerJob.perform_now
    end

    second_run = AutomationRuleRun.unscoped_for_system_job.order(:created_at).last
    assert_not_equal first_run.id, second_run.id
  end

  # === Multi-tenant Support ===

  test "processes rules across multiple tenants" do
    # Create another tenant with a scheduled rule
    tenant2 = create_tenant(subdomain: "tenant2")
    user2 = create_user(name: "User 2")
    tenant2.add_user!(user2)
    superagent2 = create_superagent(tenant: tenant2, created_by: user2)
    superagent2.add_user!(user2)
    tenant2.set_feature_flag!("ai_agents", true)
    ai_agent2 = create_ai_agent(parent: user2)
    tenant2.add_user!(ai_agent2)

    rule1 = create_scheduled_rule(cron: "* * * * *")
    rule2 = AutomationRule.create!(
      tenant: tenant2,
      ai_agent: ai_agent2,
      created_by: user2,
      name: "Tenant 2 Schedule",
      trigger_type: "schedule",
      trigger_config: { "cron" => "* * * * *" },
      actions: { "task" => "Do something for tenant 2" },
      enabled: true
    )

    # Clear context
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope

    assert_difference "AutomationRuleRun.count", 2 do
      AutomationSchedulerJob.perform_now
    end
  end

  # === Error Handling ===

  test "continues processing other rules if one fails" do
    rule1 = create_scheduled_rule(cron: "* * * * *", name: "Rule 1")
    rule2 = create_scheduled_rule(cron: "* * * * *", name: "Rule 2")

    # Force rule1 to have an invalid cron (shouldn't happen in practice,
    # but tests resilience)
    rule1.update_column(:trigger_config, { "cron" => "invalid" })

    # Should still create run for rule2
    assert_difference "AutomationRuleRun.count", 1 do
      AutomationSchedulerJob.perform_now
    end

    run = AutomationRuleRun.unscoped_for_system_job.order(:created_at).last
    assert_equal rule2.id, run.automation_rule_id
  end

  test "logs error for invalid cron expressions" do
    rule = create_scheduled_rule(cron: "* * * * *")
    rule.update_column(:trigger_config, { "cron" => "not a valid cron" })

    # Should not raise, should log the error
    assert_nothing_raised do
      AutomationSchedulerJob.perform_now
    end
  end

  # === Only Scheduled Rules ===

  test "ignores event-triggered rules" do
    # Create an event rule (not schedule)
    event_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Event Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Respond to note" },
      enabled: true
    )

    assert_no_difference "AutomationRuleRun.count" do
      AutomationSchedulerJob.perform_now
    end
  end

  test "ignores webhook-triggered rules" do
    webhook_rule = AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: "Webhook Rule",
      trigger_type: "webhook",
      trigger_config: {},
      actions: { "task" => "Handle webhook" },
      enabled: true
    )

    assert_no_difference "AutomationRuleRun.count" do
      AutomationSchedulerJob.perform_now
    end
  end

  private

  def create_scheduled_rule(cron:, timezone: "UTC", enabled: true, name: "Test Schedule")
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      created_by: @user,
      name: name,
      trigger_type: "schedule",
      trigger_config: { "cron" => cron, "timezone" => timezone },
      actions: { "task" => "Do the scheduled thing" },
      enabled: enabled
    )
  end
end
