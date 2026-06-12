require "test_helper"

class SidekiqCronScheduleTest < ActiveSupport::TestCase
  test "schedule includes billing reconciliation" do
    entry = SIDEKIQ_CRON_SCHEDULE["billing_reconciliation"]
    assert entry, "billing_reconciliation is missing from the sidekiq-cron schedule"
    assert_equal "BillingReconciliationJob", entry["class"]
    assert_match(/\A\S+ \S+ \S+ \S+ \S+\z/, entry["cron"], "cron expression should have 5 fields")
  end

  test "every scheduled class is a real job" do
    SIDEKIQ_CRON_SCHEDULE.each do |name, entry|
      klass = entry["class"].safe_constantize
      assert klass, "schedule entry #{name.inspect} references unknown class #{entry["class"].inspect}"
      assert klass < ActiveJob::Base, "schedule entry #{name.inspect} class #{entry["class"]} is not a job"
    end
  end
end
