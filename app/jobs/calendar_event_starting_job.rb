# typed: true
# frozen_string_literal: true

# CalendarEventStartingJob fires a commitment.starting event shortly before a
# calendar event's start time, so attendees get a heads-up notification (see
# NotificationDispatcher#handle_commitment_starting_event). It runs every
# minute via sidekiq-cron and mirrors DeadlineEventJob: query across all
# tenants, mark fired before dispatching so a failure can't re-fire.
class CalendarEventStartingJob < SystemJob
  extend T::Sig

  queue_as :default

  MAX_PER_RUN = 100
  # How far before starts_at the heads-up fires.
  LEAD_TIME = 1.hour

  sig { void }
  def perform
    # The ends_at guard keeps already-finished events (including the backlog
    # of events that predate this job) from firing on deploy.
    commitments = Commitment.unscoped_for_system_job
      .where(subtype: "calendar_event")
      .where(deleted_at: nil)
      .where(starting_event_fired_at: nil)
      .where(starts_at: ...(Time.current + LEAD_TIME))
      .where("ends_at > ?", Time.current)
      .includes(:tenant, :collective, :created_by)
      .limit(MAX_PER_RUN)
      .order(:starts_at)

    count = 0
    commitments.each do |commitment|
      fire_starting_event(commitment)
      count += 1
    rescue StandardError => e
      Rails.logger.error("CalendarEventStartingJob: Failed for commitment #{commitment.id}: #{e.message}")
    end

    return unless count.positive?

    Rails.logger.info("CalendarEventStartingJob: Fired #{count} commitment.starting events")
  end

  private

  sig { params(commitment: Commitment).void }
  def fire_starting_event(commitment)
    tenant = commitment.tenant
    collective = commitment.collective
    unless tenant && collective
      Rails.logger.warn(
        "CalendarEventStartingJob: Skipping commitment #{commitment.id} — missing tenant or collective"
      )
      commitment.update_column(:starting_event_fired_at, Time.current)
      return
    end

    # Mark as fired BEFORE recording the event, so that if the event dispatch
    # succeeds but a later step fails, we don't re-fire on the next run.
    # Missing an event is better than duplicating notifications.
    commitment.update_column(:starting_event_fired_at, Time.current)

    with_tenant_and_collective_context(tenant, collective) do
      EventService.record!(
        event_type: "commitment.starting",
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
