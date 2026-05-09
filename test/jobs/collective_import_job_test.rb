# typed: false

require "test_helper"

class CollectiveImportJobTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  test "purges file after successful import" do
    data_import = DataImport.create!(tenant: @tenant, user: @user, status: "pending")
    data_import.file.attach(io: StringIO.new("fake zip"), filename: "test.zip", content_type: "application/zip")

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    fake_service = Object.new
    fake_service.define_singleton_method(:perform!) {}

    CollectiveImportService.stub(:new, ->(**) { fake_service }) do
      CollectiveImportJob.new.perform(data_import.id)
    end

    data_import.reload
    assert_not data_import.file.attached?
  end

  test "retains file when import fails" do
    data_import = DataImport.create!(tenant: @tenant, user: @user, status: "pending")
    data_import.file.attach(io: StringIO.new("fake zip"), filename: "test.zip", content_type: "application/zip")

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    fake_service = Object.new
    fake_service.define_singleton_method(:perform!) { raise StandardError, "boom" }

    assert_raises(StandardError) do
      CollectiveImportService.stub(:new, ->(**) { fake_service }) do
        CollectiveImportJob.new.perform(data_import.id)
      end
    end

    data_import.reload
    assert data_import.file.attached?
  end

  test "skips non-pending imports without touching the file" do
    data_import = DataImport.create!(tenant: @tenant, user: @user, status: "completed")
    data_import.file.attach(io: StringIO.new("fake zip"), filename: "test.zip", content_type: "application/zip")

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    CollectiveImportJob.new.perform(data_import.id)

    data_import.reload
    assert data_import.file.attached?
  end
end
