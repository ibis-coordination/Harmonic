# typed: true
# frozen_string_literal: true

# CalendarEventStartingJob fires the two start-related events for calendar
# events, so attendees get notified both ahead of time and at the moment the
# event begins (see NotificationDispatcher#handle_commitment_starting_soon_event
# and #handle_commitment_starting_event):
#
#   - commitment.starting_soon — a heads-up LEAD_TIME before starts_at
#   - commitment.starting      — when starts_at is reached
#
# It runs every minute via sidekiq-cron and mirrors DeadlineEventJob: query
# across all tenants, mark fired before dispatching so a failure can't re-fire.
class CalendarEventStartingJob < SystemJob
  extend T::Sig

  queue_as :default

  MAX_PER_RUN = 100
  # How far before starts_at the "starting soon" heads-up fires.
  LEAD_TIME = 1.hour
  # How long after starts_at we'll still fire the "starting" event. Keeps the
  # backlog of long-running events that were already underway at deploy time
  # (or when the job was down) from firing a stale "starting now" blast; the
  # minutely cadence means a few minutes of slack is plenty for the normal case.
  STARTED_GRACE = 5.minutes

  sig { void }
  def perform
    now = Time.current
    soon_count = process(scope_starting_soon(now), "commitment.starting_soon", :starting_soon_event_fired_at)
    starting_count = process(scope_starting(now), "commitment.starting", :starting_event_fired_at)

    total = soon_count + starting_count
    return unless total.positive?

    Rails.logger.info(
      "CalendarEventStartingJob: Fired #{total} start events " \
      "(#{soon_count} starting_soon, #{starting_count} starting)"
    )
  end

  private

  sig { params(now: ActiveSupport::TimeWithZone).returns(ActiveRecord::Relation) }
  def scope_starting_soon(now)
    # Future start within the lead window that hasn't ended yet. The ends_at
    # guard keeps already-finished events (including the pre-existing backlog)
    # from firing on deploy.
    base_scope
      .where(starting_soon_event_fired_at: nil)
      .where("starts_at > ?", now)
      .where(starts_at: ..(now + LEAD_TIME))
      .where("ends_at > ?", now)
      .order(:starts_at)
  end

  sig { params(now: ActiveSupport::TimeWithZone).returns(ActiveRecord::Relation) }
  def scope_starting(now)
    # Start time just reached (within STARTED_GRACE) and not yet ended.
    base_scope
      .where(starting_event_fired_at: nil)
      .where(starts_at: (now - STARTED_GRACE)..now)
      .where("ends_at > ?", now)
      .order(:starts_at)
  end

  sig { returns(ActiveRecord::Relation) }
  def base_scope
    Commitment.unscoped_for_system_job
      .where(subtype: "calendar_event")
      .where(deleted_at: nil)
      .includes(:tenant, :collective, :created_by)
      .limit(MAX_PER_RUN)
  end

  sig { params(scope: ActiveRecord::Relation, event_type: String, column: Symbol).returns(Integer) }
  def process(scope, event_type, column)
    count = 0
    scope.each do |commitment|
      fire_event(commitment, event_type, column)
      count += 1
    rescue StandardError => e
      Rails.logger.error("CalendarEventStartingJob: Failed for commitment #{commitment.id} (#{event_type}): #{e.message}")
    end
    count
  end

  sig { params(commitment: Commitment, event_type: String, column: Symbol).void }
  def fire_event(commitment, event_type, column)
    tenant = commitment.tenant
    collective = commitment.collective
    unless tenant && collective
      Rails.logger.warn(
        "CalendarEventStartingJob: Skipping commitment #{commitment.id} — missing tenant or collective"
      )
      commitment.update_column(column, Time.current)
      return
    end

    # Mark as fired BEFORE recording the event, so that if the event dispatch
    # succeeds but a later step fails, we don't re-fire on the next run.
    # Missing an event is better than duplicating notifications.
    commitment.update_column(column, Time.current)

    with_tenant_and_collective_context(tenant, collective) do
      EventService.record!(
        event_type: event_type,
        actor: commitment.created_by,
        subject: commitment,
        metadata: {
          "resource_type" => "commitment",
          "resource_id" => commitment.id,
          "title" => commitment.title,
          "starts_at" => commitment.starts_at&.iso8601,
          "ends_at" => commitment.ends_at&.iso8601,
          "location" => commitment.location,
        }
      )
    end
  end
end
