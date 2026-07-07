require "test_helper"

# Locks in the execute-time authorization gate (ActionAuthorizationCheck): every
# /actions/<name> POST runs ACTION_DEFINITIONS[name][:authorization] before the
# controller's execute method, and denies with 403 when the rule rejects the
# caller — independent of whatever authorize_* the controller declares.
#
# Grant-permission enforcement and the session-ending exemption are covered in
# api_representation_test.rb, which already carries the representation plumbing.
class ActionAuthorizationGateTest < ActionDispatch::IntegrationTest
  def setup
    @tenant, @collective, @member = create_tenant_collective_user
    @tenant.create_main_collective!(created_by: @member) unless @tenant.main_collective
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    # A human who belongs to the tenant but NOT the collective.
    @non_member = create_user(name: "Non Member")
    @tenant.add_user!(@non_member)
  end

  # ---- :collective_member action (create_note) across caller types ----

  test "collective member can execute a collective_member-scoped action" do
    sign_in_as(@member, tenant: @tenant)

    post "/collectives/#{@collective.handle}/note/actions/create_note",
         params: { title: "Hi", text: "Body" },
         headers: { "Accept" => "text/markdown" }

    assert_response :success
  end

  test "non-member human cannot execute a collective_member-scoped action" do
    sign_in_as(@non_member, tenant: @tenant)

    assert_no_difference -> { Note.count } do
      post "/collectives/#{@collective.handle}/note/actions/create_note",
           params: { title: "Hi", text: "Body" },
           headers: { "Accept" => "text/markdown" }
    end

    # Denied — the collective controller redirects non-members to /join before
    # the gate; either way no note is created and the write does not succeed.
    assert_not_equal 200, response.status
  end

  test "anonymous request cannot execute a collective_member-scoped action" do
    assert_no_difference -> { Note.count } do
      post "/collectives/#{@collective.handle}/note/actions/create_note",
           params: { title: "Hi", text: "Body" },
           headers: { "Accept" => "text/markdown" }
    end

    assert_not_equal 200, response.status
  end

  # ---- NOTE_EDIT_AUTHORIZATION (cancel_reminder) author vs non-author ----
  # Regression guard for the former `authorization: :owner` typo, which was an
  # undefined check and therefore denied everyone (including the author).

  test "note author can cancel their own reminder; a non-author member cannot" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    notification = ReminderService.create!(
      user: @member,
      title: "T",
      scheduled_for: 1.day.from_now.in_time_zone("UTC")
    )
    note = Note.create!(
      tenant: @tenant, collective: @collective, created_by: @member, updated_by: @member,
      text: "Reminder", subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC")
    )

    # A second collective member who did not author the note.
    other_member = create_user(name: "Other Member")
    @tenant.add_user!(other_member)
    @collective.add_user!(other_member)
    sign_in_as(other_member, tenant: @tenant)
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/cancel_reminder",
         headers: { "Accept" => "text/markdown" }
    assert_response :forbidden, "non-author member should be denied by the gate"
    assert_not_nil note.reload.reminder_notification_id

    sign_in_as(@member, tenant: @tenant)
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/cancel_reminder",
         headers: { "Accept" => "text/markdown" }
    assert_response :success, "author should be allowed"
    assert_nil note.reload.reminder_notification_id
  end
end
