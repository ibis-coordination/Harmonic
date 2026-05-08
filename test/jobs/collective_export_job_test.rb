# typed: false

require "test_helper"

class CollectiveExportJobTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  test "performs export and marks as completed" do
    data_export = DataExport.create!(tenant: @tenant, collective: @collective, user: @user, status: "pending")

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    CollectiveExportJob.new.perform(data_export.id)

    data_export.reload
    assert_equal "completed", data_export.status
    assert data_export.file.attached?
  end

  test "skips non-pending exports" do
    data_export = DataExport.create!(tenant: @tenant, collective: @collective, user: @user, status: "completed")

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    CollectiveExportJob.new.perform(data_export.id)

    data_export.reload
    assert_equal "completed", data_export.status
    assert_not data_export.file.attached?
  end
end
