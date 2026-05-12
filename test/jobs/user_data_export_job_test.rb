# typed: false

require "test_helper"

class UserDataExportJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.update!(main_collective: @collective) if @tenant.main_collective_id.nil?
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  test "performs export, marks completed, and enqueues the user-export email" do
    data_export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "user",
    )
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      UserDataExportJob.new.perform(data_export.id)
    end

    data_export.reload
    assert_equal "completed", data_export.status
    assert data_export.file.attached?
  end

  test "skips non-pending exports" do
    data_export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", export_type: "user",
    )
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    UserDataExportJob.new.perform(data_export.id)

    data_export.reload
    assert_equal "completed", data_export.status
    refute data_export.file.attached?
  end

  test "skips collective-type exports (separate job handles those)" do
    data_export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "collective",
    )
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    UserDataExportJob.new.perform(data_export.id)

    data_export.reload
    assert_equal "pending", data_export.status, "must not process collective exports"
  end
end
