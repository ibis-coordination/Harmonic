# typed: false

require "test_helper"

class SweepStuckDataImportsJobTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
  end

  test "marks importing imports older than threshold as failed" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    stuck = DataImport.create!(tenant: @tenant, user: @user, status: "importing", started_at: 2.hours.ago)
    Tenant.clear_thread_scope

    SweepStuckDataImportsJob.new.perform

    stuck.reload
    assert_equal "failed", stuck.status
    assert_match(/did not complete/i, stuck.error_message)
  end

  test "marks pending imports older than threshold as failed (uses created_at)" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    stuck = DataImport.create!(tenant: @tenant, user: @user, status: "pending")
    stuck.update_columns(created_at: 2.hours.ago, started_at: nil)
    Tenant.clear_thread_scope

    SweepStuckDataImportsJob.new.perform

    stuck.reload
    assert_equal "failed", stuck.status
  end

  test "leaves recent in-progress imports alone" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    fresh = DataImport.create!(tenant: @tenant, user: @user, status: "importing", started_at: 5.minutes.ago)
    Tenant.clear_thread_scope

    SweepStuckDataImportsJob.new.perform

    fresh.reload
    assert_equal "importing", fresh.status
  end

  test "leaves terminal-status imports alone" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    completed = DataImport.create!(tenant: @tenant, user: @user, status: "completed", started_at: 2.hours.ago, completed_at: 1.hour.ago)
    failed = DataImport.create!(tenant: @tenant, user: @user, status: "failed", started_at: 2.hours.ago)
    Tenant.clear_thread_scope

    SweepStuckDataImportsJob.new.perform

    completed.reload
    failed.reload
    assert_equal "completed", completed.status
    assert_equal "failed", failed.status
  end
end
