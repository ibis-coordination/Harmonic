# typed: true
# frozen_string_literal: true

class LotteryDrawJob < TenantScopedJob
  extend T::Sig

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  sig { params(decision_id: String).void }
  def perform(decision_id)
    decision = Decision.unscoped_for_system_job.find_by(id: decision_id)
    return unless decision
    return unless decision.is_lottery? || decision.is_vote?
    return unless decision.closed?
    return if decision.beacon_drawn?

    set_tenant_context!(decision.tenant)

    # The target drand round is determined by the deadline, but that round
    # won't be published until after the deadline. If the deadline is still
    # in the future, reschedule for after it passes.
    if decision.deadline > Time.current
      self.class.set(wait_until: decision.deadline + 5.seconds).perform_later(decision_id)
      return
    end

    LotteryService.new.draw!(decision)
  end
end
