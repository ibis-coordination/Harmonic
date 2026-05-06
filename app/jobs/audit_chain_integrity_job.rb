# typed: true
# frozen_string_literal: true

class AuditChainIntegrityJob < SystemJob
  extend T::Sig

  sig { void }
  def perform
    Decision.unscoped_for_system_job.where("created_at >= ?", Decision::AUDIT_CHAIN_LAUNCH_DATE).find_each do |decision|
      results = self.class.check_decision(decision)
      unless results[:chain_valid] && results[:missing_audit_entries] == 0
        Rails.logger.warn(
          "[AuditChainIntegrity] Decision #{decision.id}: " \
          "chain_valid=#{results[:chain_valid]}, " \
          "missing_audit_entries=#{results[:missing_audit_entries]}, " \
          "errors=#{results[:errors].join('; ')}",
        )
      end
    end
  end

  sig { params(decision: Decision).returns(T::Hash[Symbol, T.untyped]) }
  def self.check_decision(decision)
    unless decision.audit_chain_enabled?
      return { chain_valid: true, missing_audit_entries: 0, errors: [], skipped: true }
    end

    # Verify chain integrity
    chain_result = DecisionAuditVerifier.verify_chain(decision)

    # Check for votes without audit entries
    vote_count = Vote.unscoped_for_system_job.where(decision_id: decision.id).count
    audit_vote_count = DecisionAuditEntry.unscoped_for_system_job.where(
      decision_id: decision.id,
      action: %w[vote_cast vote_updated],
    ).count
    missing = [vote_count - audit_vote_count, 0].max

    {
      chain_valid: chain_result[:valid],
      missing_audit_entries: missing,
      errors: chain_result[:errors],
      entry_count: chain_result[:entry_count],
      skipped: false,
    }
  end
end
