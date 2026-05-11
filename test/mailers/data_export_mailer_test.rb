# typed: false

require "test_helper"

class DataExportMailerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", expires_at: 7.days.from_now,
      record_counts: { "notes" => 5, "decisions" => 2 },
    )
  end

  test "export_ready email has correct subject and recipient" do
    email = DataExportMailer.export_ready(data_export: @export)
    assert_equal [@user.email], email.to
    assert_includes email.subject, @collective.name
    assert_includes email.subject, "data export"
  end

  test "export_ready email body includes collective name and record counts" do
    email = DataExportMailer.export_ready(data_export: @export)
    body = email.body.encoded
    assert_includes body, @collective.name
    assert_includes body, "5 notes"
    assert_includes body, "2 decisions"
  end

  test "export_ready email body includes download link" do
    email = DataExportMailer.export_ready(data_export: @export)
    body = email.body.encoded
    assert_includes body, "/exports/#{@export.id}"
  end

  test "export job sends email after successful export" do
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user, status: "pending",
    )

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    fake_service = Object.new
    fake_service.define_singleton_method(:perform!) {}

    CollectiveExportService.stub(:new, ->(**) { fake_service }) do
      assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
        CollectiveExportJob.new.perform(export.id)
      end
    end
  end

  test "export job does not send email when export fails" do
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user, status: "pending",
    )

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    service_stub = ->(data_export:) {
      fake = Object.new
      fake.define_singleton_method(:perform!) do
        data_export.update!(status: "failed", error_message: "zip error")
        raise StandardError, "zip error"
      end
      fake
    }

    assert_enqueued_jobs 0, only: ActionMailer::MailDeliveryJob do
      assert_raises(StandardError) do
        CollectiveExportService.stub(:new, service_stub) do
          CollectiveExportJob.new.perform(export.id)
        end
      end
    end
  end

  # --- user_export_ready ---

  test "user_export_ready email has correct subject and recipient" do
    user_export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", expires_at: 7.days.from_now,
      export_type: "user",
      record_counts: { "notes" => 3, "votes" => 4 },
    )
    email = DataExportMailer.user_export_ready(data_export: user_export)
    assert_equal [@user.email], email.to
    assert_match(/personal data export/i, email.subject)
    refute_includes email.subject, @collective.name, "user export subject should not name a collective"
  end

  test "user_export_ready email body includes record counts and the user-scoped download link" do
    user_export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", expires_at: 7.days.from_now,
      export_type: "user",
      record_counts: { "notes" => 3, "votes" => 4 },
    )
    email = DataExportMailer.user_export_ready(data_export: user_export)
    body = email.body.encoded
    assert_includes body, "3 notes"
    assert_includes body, "4 votes"
    handle = @user.tenant_users.find_by(tenant_id: @tenant.id).handle
    assert_includes body, "/u/#{handle}/settings/data-export/#{user_export.id}",
                     "download URL must match the actual controller route (/u/:handle/settings/data-export/:id)"
  end
end
