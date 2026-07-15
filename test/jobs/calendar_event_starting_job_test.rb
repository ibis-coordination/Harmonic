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

  def run_job
    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  # --- starting_soon (the lead-window heads-up) -----------------------------

  test "fires commitment.starting_soon for events starting within the lead window" do
    event_commitment = create_event(starts_at: 30.minutes.from_now)

    run_job

    event = Event.where(event_type: "commitment.starting_soon").last
    assert_not_nil event
    assert_equal event_commitment.id, event.subject_id
    assert_not_nil event_commitment.reload.starting_soon_event_fired_at
    # The event hasn't actually started yet, so the "starting" event stays armed.
    assert_nil event_commitment.reload.starting_event_fired_at
  end

  test "starting_soon notifies the creator and committed participants" do
    attendee = create_user(name: "Attendee")
    @tenant.add_user!(attendee)
    @collective.add_user!(attendee)
    event_commitment = create_event(starts_at: 30.minutes.from_now)
    event_commitment.join_commitment!(attendee)

    run_job

    notifications = Notification.where(notification_type: "event_starting_soon")
    assert_equal 2, notifications.count
    recipient_ids = NotificationRecipient
      .where(notification: notifications, channel: "in_app")
      .pluck(:user_id)
    assert_includes recipient_ids, @user.id
    assert_includes recipient_ids, attendee.id
  end

  test "does not fire starting_soon for events starting beyond the lead window" do
    event_commitment = create_event(starts_at: 2.days.from_now)

    run_job

    assert_nil Event.find_by(event_type: "commitment.starting_soon", subject_id: event_commitment.id)
    assert_nil event_commitment.reload.starting_soon_event_fired_at
  end

  test "does not fire starting_soon twice for the same event" do
    create_event(starts_at: 30.minutes.from_now)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_equal 1, Event.where(event_type: "commitment.starting_soon").count
  end

  # --- starting (at the actual start time) ----------------------------------

  test "fires commitment.starting when the start time has just arrived" do
    event_commitment = create_event(starts_at: 1.minute.ago, ends_at: 59.minutes.from_now)

    run_job

    event = Event.where(event_type: "commitment.starting").last
    assert_not_nil event
    assert_equal event_commitment.id, event.subject_id
    assert_not_nil event_commitment.reload.starting_event_fired_at
    # It already started, so the heads-up window never applied.
    assert_nil event_commitment.reload.starting_soon_event_fired_at
  end

  test "starting notifies the creator and committed participants" do
    attendee = create_user(name: "Attendee")
    @tenant.add_user!(attendee)
    @collective.add_user!(attendee)
    event_commitment = create_event(starts_at: 1.minute.ago, ends_at: 59.minutes.from_now)
    event_commitment.join_commitment!(attendee)

    run_job

    notifications = Notification.where(notification_type: "event_starting")
    assert_equal 2, notifications.count
    recipient_ids = NotificationRecipient
      .where(notification: notifications, channel: "in_app")
      .pluck(:user_id)
    assert_includes recipient_ids, @user.id
    assert_includes recipient_ids, attendee.id
  end

  test "does not fire starting for events whose start passed beyond the grace window" do
    event_commitment = create_event(starts_at: 30.minutes.ago, ends_at: 30.minutes.from_now)

    run_job

    assert_nil Event.find_by(event_type: "commitment.starting", subject_id: event_commitment.id)
    assert_nil event_commitment.reload.starting_event_fired_at
  end

  test "does not fire starting twice for the same event" do
    create_event(starts_at: 1.minute.ago, ends_at: 59.minutes.from_now)

    Collective.clear_thread_scope
    CalendarEventStartingJob.perform_now
    CalendarEventStartingJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    assert_equal 1, Event.where(event_type: "commitment.starting").count
  end

  # --- guards shared by both ------------------------------------------------

  test "does not fire for events that have already ended" do
    event_commitment = nil
    travel_to 3.days.ago do
      event_commitment = create_event(starts_at: 1.hour.from_now)
    end

    run_job

    assert_nil Event.find_by(event_type: "commitment.starting_soon", subject_id: event_commitment.id)
    assert_nil Event.find_by(event_type: "commitment.starting", subject_id: event_commitment.id)
  end

  test "does not fire for soft-deleted events" do
    soon = create_event(starts_at: 30.minutes.from_now)
    starting = create_event(starts_at: 1.minute.ago, ends_at: 59.minutes.from_now)
    soon.update_columns(deleted_at: Time.current)
    starting.update_columns(deleted_at: Time.current)

    run_job

    assert_nil Event.find_by(event_type: "commitment.starting_soon", subject_id: soon.id)
    assert_nil Event.find_by(event_type: "commitment.starting", subject_id: starting.id)
  end

  # --- reschedule re-arming -------------------------------------------------

  test "rescheduling an event re-arms both start notifications" do
    event_commitment = create_event(starts_at: 30.minutes.from_now)

    run_job

    assert_not_nil event_commitment.reload.starting_soon_event_fired_at

    new_start = 3.days.from_now
    event_commitment.update!(starts_at: new_start, ends_at: new_start + 1.hour)
    assert_nil event_commitment.reload.starting_soon_event_fired_at
    assert_nil event_commitment.reload.starting_event_fired_at
  end

  test "nudging an imminent event does not re-arm the starting_soon notification" do
    event_commitment = create_event(starts_at: 30.minutes.from_now)

    run_job

    new_start = 45.minutes.from_now
    event_commitment.reload.update!(starts_at: new_start, ends_at: new_start + 1.hour)
    assert_not_nil event_commitment.reload.starting_soon_event_fired_at
  end
end
