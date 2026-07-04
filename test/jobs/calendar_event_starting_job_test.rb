# typed: false

require "test_helper"

class CalendarEventStartingJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Collective.clear_thread_scope
  end

  def create_event(starts_at:, ends_at: nil)
    Commitment.create!(
      tenant: @tenant, collective: @collective,
      created_by: @user, updated_by: @user,
      title: "Test event", description: "",
      subtype: "calendar_event",
      critical_mass: 1,
      deadline: starts_at,
      starts_at: starts_at,
      ends_at: ends_at || starts_at + 1.hour
    )
  end

  test "fires commitment.starting for events starting within the lead window" do
    event_commitment = create_event(starts_at: 30.minutes.from_now)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    event = Event.where(event_type: "commitment.starting").last
    assert_not_nil event
    assert_equal event_commitment.id, event.subject_id
    assert_not_nil event_commitment.reload.starting_event_fired_at
  end

  test "notifies the creator and committed participants" do
    attendee = create_user(name: "Attendee")
    @tenant.add_user!(attendee)
    @collective.add_user!(attendee)
    event_commitment = create_event(starts_at: 30.minutes.from_now)
    event_commitment.join_commitment!(attendee)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # notify_user creates one Notification per recipient
    notifications = Notification.where(notification_type: "event_starting")
    assert_equal 2, notifications.count
    recipient_ids = NotificationRecipient
      .where(notification: notifications, channel: "in_app")
      .pluck(:user_id)
    assert_includes recipient_ids, @user.id
    assert_includes recipient_ids, attendee.id
  end

  test "does not fire for events starting beyond the lead window" do
    event_commitment = create_event(starts_at: 2.days.from_now)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_nil Event.find_by(event_type: "commitment.starting", subject_id: event_commitment.id)
    assert_nil event_commitment.reload.starting_event_fired_at
  end

  test "does not fire for events that have already ended" do
    event_commitment = nil
    travel_to 3.days.ago do
      event_commitment = create_event(starts_at: 1.hour.from_now)
    end

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_nil Event.find_by(event_type: "commitment.starting", subject_id: event_commitment.id)
  end

  test "does not fire twice for the same event" do
    create_event(starts_at: 30.minutes.from_now)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_equal 1, Event.where(event_type: "commitment.starting").count
  end

  test "does not fire for soft-deleted events" do
    event_commitment = create_event(starts_at: 30.minutes.from_now)
    event_commitment.update_columns(deleted_at: Time.current)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_nil Event.find_by(event_type: "commitment.starting", subject_id: event_commitment.id)
  end

  test "rescheduling an event re-arms the starting notification" do
    event_commitment = create_event(starts_at: 30.minutes.from_now)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_not_nil event_commitment.reload.starting_event_fired_at

    new_start = 3.days.from_now
    event_commitment.update!(starts_at: new_start, ends_at: new_start + 1.hour)
    assert_nil event_commitment.reload.starting_event_fired_at
  end

  test "nudging an imminent event does not re-arm the notification" do
    event_commitment = create_event(starts_at: 30.minutes.from_now)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    new_start = 45.minutes.from_now
    event_commitment.reload.update!(starts_at: new_start, ends_at: new_start + 1.hour)
    assert_not_nil event_commitment.reload.starting_event_fired_at
  end
end
