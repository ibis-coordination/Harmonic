# typed: true
# frozen_string_literal: true

# DeadlineEventJob fires events when decision or commitment deadlines pass.
# It runs every minute (via sidekiq-cron) and queries across all tenants for
# items whose deadlines have passed but haven't had their event fired yet.
#
# Events fired:
#   - decision.deadline_reached
#   - commitment.deadline_reached
#
# For lottery decisions, also enqueues LotteryDrawJob.
class DeadlineEventJob < SystemJob
  extend T::Sig

  queue_as :default

  MAX_PER_RUN = 100

  sig { void }
  def perform
    decision_count = process_decisions
    commitment_count = process_commitments

    total = decision_count + commitment_count
    return unless total.positive?

    Rails.logger.info(
      "DeadlineEventJob: Fired #{total} deadline events " \
      "(#{decision_count} decisions, #{commitment_count} commitments)"
    )
  end

  private

  sig { returns(Integer) }
  def process_decisions
    decisions = Decision.unscoped_for_system_job
      .where(deleted_at: nil)
      .where(deadline: ...Time.current)
      .where(deadline_event_fired_at: nil)
      .includes(:tenant, :collective, :created_by)
      .limit(MAX_PER_RUN)
      .order(:deadline)

    count = 0
    decisions.each do |decision|
      fire_deadline_event(decision)
      count += 1
    rescue StandardError => e
      Rails.logger.error("DeadlineEventJob: Failed for decision #{decision.id}: #{e.message}")
      increment_error_counter("decision")
    end
    count
  end

  sig { returns(Integer) }
  def process_commitments
    commitments = Commitment.unscoped_for_system_job
      .where(deleted_at: nil)
      .where(deadline: ...Time.current)
      .where(deadline_event_fired_at: nil)
      .includes(:tenant, :collective, :created_by)
      .limit(MAX_PER_RUN)
      .order(:deadline)

    count = 0
    commitments.each do |commitment|
      fire_deadline_event(commitment)
      count += 1
    rescue StandardError => e
      Rails.logger.error("DeadlineEventJob: Failed for commitment #{commitment.id}: #{e.message}")
      increment_error_counter("commitment")
    end
    count
  end

  sig { params(resource: T.any(Decision, Commitment)).void }
  def fire_deadline_event(resource)
    tenant = resource.tenant
    collective = resource.collective
    unless tenant && collective
      Rails.logger.warn(
        "DeadlineEventJob: Skipping #{resource.class.name} #{resource.id} — missing tenant or collective"
      )
      resource.update_column(:deadline_event_fired_at, Time.current)
      return
    end

    event_type = "#{T.must(resource.class.name).underscore}.deadline_reached"

    # Mark as fired BEFORE recording the event, so that if the event dispatch
    # succeeds but a later step fails, we don't re-fire on the next run.
    # Missing an event is better than duplicating webhooks.
    resource.update_column(:deadline_event_fired_at, Time.current)

    with_tenant_and_collective_context(tenant, collective) do
      EventService.record!(
        event_type: event_type,
        actor: resource.created_by,
        subject: resource,
        metadata: event_metadata(resource)
      )

      LotteryDrawJob.perform_later(resource.id) if resource.is_a?(Decision) && resource.is_lottery?
    end

    increment_fired_counter(T.must(resource.class.name).underscore)
  end

  sig { params(resource_type: String).void }
  def increment_fired_counter(resource_type)
    return if Rails.env.test?

    Yabeda.deadline_events.fired_total.increment({ resource_type: resource_type })
  end

  sig { params(resource_type: String).void }
  def increment_error_counter(resource_type)
    return if Rails.env.test?

    Yabeda.deadline_events.errors_total.increment({ resource_type: resource_type })
  end

  sig { params(resource: T.any(Decision, Commitment)).returns(T::Hash[String, T.untyped]) }
  def event_metadata(resource)
    metadata = {
      "resource_type" => T.must(resource.class.name).underscore,
      "resource_id" => resource.id,
      "deadline" => resource.deadline&.iso8601,
    }

    case resource
    when Decision
      metadata["question"] = resource.question
      metadata["subtype"] = resource.subtype
    when Commitment
      metadata["title"] = resource.title
    end

    metadata
  end
end
