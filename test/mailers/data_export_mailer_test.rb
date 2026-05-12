# typed: false

require "test_helper"

class DataExportMailerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.update!(main_collective: @collective)
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

  test "export_ready download URL actually routes to the download_export action" do
    # Parallel to the user-export routing test. Pins that whatever URL
    # we build resolves to the collective download action via the
    # router — catches the class of bug where the mailer URL drifts
    # away from the actual route (or the route is removed/renamed).
    #
    # Uses a non-main collective because Collective#url drops the path
    # for the tenant's main_collective, which the mailer's URL building
    # doesn't account for (a pre-existing edge case not in this PR's scope).
    other_collective = create_collective(tenant: @tenant, created_by: @user, name: "Other", handle: "other-#{SecureRandom.hex(4)}")
    other_collective.add_user!(@user)
    export = DataExport.create!(
      tenant: @tenant, collective: other_collective, user: @user,
      status: "completed", expires_at: 7.days.from_now,
      record_counts: { "notes" => 1 },
    )

    email = DataExportMailer.export_ready(data_export: export)
    html_body = T.must(email.parts.find { |p| p.content_type.start_with?("text/html") }).body.encoded
    href = T.must(html_body.match(%r{href="([^"]+/exports/[^"]+)"}))[1]
    path = URI.parse(T.must(href)).path

    routed = Rails.application.routes.recognize_path(path, method: :get)
    assert_equal "collective_data_transfers", routed[:controller]
    assert_equal "download_export", routed[:action]
    assert_equal export.id, routed[:id]
    assert_equal other_collective.handle, routed[:collective_handle]
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

  test "user_export_ready download URL actually routes to the download action" do
    # Earlier in development the mailer URL was wrong (pointed at
    # /settings/data_export/:id which doesn't exist). The string-match
    # tests above caught it after the fact; this test pins the contract
    # — the URL we generate must resolve via Rails routing to the
    # download action, with the right export_id. If either the route
    # or the mailer drifts, this fails.
    user_export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "completed", expires_at: 7.days.from_now, export_type: "user",
    )
    email = DataExportMailer.user_export_ready(data_export: user_export)

    # Pull the link out of the HTML body.
    html_body = T.must(email.parts.find { |p| p.content_type.start_with?("text/html") }).body.encoded
    href = T.must(html_body.match(%r{href="([^"]+/settings/data-export/[^"]+)"}))[1]
    path = URI.parse(T.must(href)).path

    routed = Rails.application.routes.recognize_path(path, method: :get)
    assert_equal "user_data_exports", routed[:controller]
    assert_equal "download", routed[:action]
    assert_equal user_export.id, routed[:export_id]
  end

  # --- End-to-end: real service output renders cleanly in the mailer ---
  #
  # The other tests in this file build DataExport rows with hand-crafted
  # record_counts. That misses bugs where the SERVICE produces a shape
  # the MAILER can't render — exactly the kind of integration gap that
  # let a "nested record_counts" mismatch slip past during development.
  # This test pipes the real service output into the real mailer.

  test "user_export_ready renders cleanly against the real service's output (parent only)" do
    create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "A", text: "a")
    create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "B", text: "b")
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "user",
    )
    UserDataExportService.new(data_export: export).perform!
    export.reload

    email = DataExportMailer.user_export_ready(data_export: export)
    body = email.body.encoded
    assert_match(/2 notes/, body)
    refute_match(/\{\S/, body, "body must not contain a stringified hash (sign of nested-shape leakage)")
    refute_match(/=>/, body, "body must not contain Ruby hash arrows (record_counts must be flat strings)")
  end

  test "user_export_ready renders cleanly when an AI agent contributes too (counts include both views)" do
    ai_agent = create_ai_agent(parent: @user)
    @tenant.add_user!(ai_agent)
    @collective.add_user!(ai_agent)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Parent A", text: "p")
    create_note(tenant: @tenant, collective: @collective, created_by: ai_agent, title: "Agent A", text: "a")
    create_note(tenant: @tenant, collective: @collective, created_by: ai_agent, title: "Agent B", text: "b")

    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: @user,
      status: "pending", export_type: "user",
    )
    UserDataExportService.new(data_export: export).perform!
    export.reload

    # Flat sum across views: 1 (parent) + 2 (agent) = 3 notes.
    assert_equal 3, export.record_counts["notes"],
                 "DB record_counts must be a flat {type => total} map (parent + AI agent counts combined)"

    email = DataExportMailer.user_export_ready(data_export: export)
    body = email.body.encoded
    assert_match(/3 notes/, body)
    refute_match(/\{\S/, body)
    refute_match(/=>/, body)
  end
end
