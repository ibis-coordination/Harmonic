# typed: false

class BackfillSearchIndexJob < ApplicationJob
  queue_as :low_priority

  def perform(tenant_id: nil)
    Rails.logger.info "Starting search index backfill..."

    if tenant_id
      backfill_tenant(tenant_id)
    else
      Tenant.unscoped.find_each { |tenant| backfill_tenant(tenant.id) }
    end

    Rails.logger.info "Search index backfill complete."
  end

  private

  def backfill_tenant(tenant_id)
    Rails.logger.info "Backfilling tenant: #{tenant_id}"

    backfill_notes(tenant_id)
    backfill_decisions(tenant_id)
    backfill_commitments(tenant_id)
    backfill_user_status(tenant_id)
  end

  def backfill_notes(tenant_id)
    Note.unscoped.where(tenant_id: tenant_id).find_each(batch_size: 100) do |note|
      SearchIndexer.reindex(note)
    rescue StandardError => e
      Rails.logger.error "Failed to index Note #{note.id}: #{e.message}"
    end
  end

  def backfill_decisions(tenant_id)
    Decision.unscoped.where(tenant_id: tenant_id).find_each(batch_size: 100) do |decision|
      SearchIndexer.reindex(decision)
    rescue StandardError => e
      Rails.logger.error "Failed to index Decision #{decision.id}: #{e.message}"
    end
  end

  def backfill_commitments(tenant_id)
    Commitment.unscoped.where(tenant_id: tenant_id).find_each(batch_size: 100) do |commitment|
      SearchIndexer.reindex(commitment)
    rescue StandardError => e
      Rails.logger.error "Failed to index Commitment #{commitment.id}: #{e.message}"
    end
  end

  def backfill_user_status(tenant_id)
    backfill_note_reads(tenant_id)
    backfill_decision_votes(tenant_id)
    backfill_commitment_participations(tenant_id)
    backfill_creators(tenant_id)
  end

  def backfill_note_reads(tenant_id)
    NoteHistoryEvent.unscoped
      .where(tenant_id: tenant_id, event_type: "read_confirmation")
      .find_each(batch_size: 100) do |event|
      UserItemStatus.upsert(
        {
          id: SecureRandom.uuid,
          tenant_id: event.tenant_id,
          user_id: event.user_id,
          item_type: "Note",
          item_id: event.note_id,
          has_read: true,
          read_at: event.happened_at,
        },
        unique_by: [:tenant_id, :user_id, :item_type, :item_id]
      )
    rescue StandardError => e
      Rails.logger.error "Failed to backfill read status for NoteHistoryEvent #{event.id}: #{e.message}"
    end
  end

  def backfill_decision_votes(tenant_id)
    # Find all decision participants who have voted (have at least one vote)
    DecisionParticipant.unscoped
      .joins(:votes)
      .where(tenant_id: tenant_id)
      .where.not(user_id: nil)
      .distinct
      .find_each(batch_size: 100) do |participant|
      first_vote = participant.votes.order(:created_at).first
      UserItemStatus.upsert(
        {
          id: SecureRandom.uuid,
          tenant_id: participant.tenant_id,
          user_id: participant.user_id,
          item_type: "Decision",
          item_id: participant.decision_id,
          has_voted: true,
          voted_at: first_vote&.created_at,
        },
        unique_by: [:tenant_id, :user_id, :item_type, :item_id]
      )
    rescue StandardError => e
      Rails.logger.error "Failed to backfill vote status for DecisionParticipant #{participant.id}: #{e.message}"
    end
  end

  def backfill_commitment_participations(tenant_id)
    CommitmentParticipant.unscoped
      .where(tenant_id: tenant_id)
      .where.not(user_id: nil)
      .where.not(committed_at: nil)
      .find_each(batch_size: 100) do |participant|
      UserItemStatus.upsert(
        {
          id: SecureRandom.uuid,
          tenant_id: participant.tenant_id,
          user_id: participant.user_id,
          item_type: "Commitment",
          item_id: participant.commitment_id,
          is_participating: true,
          participated_at: participant.committed_at,
        },
        unique_by: [:tenant_id, :user_id, :item_type, :item_id]
      )
    rescue StandardError => e
      Rails.logger.error "Failed to backfill participation for CommitmentParticipant #{participant.id}: #{e.message}"
    end
  end

  def backfill_creators(tenant_id)
    backfill_note_creators(tenant_id)
    backfill_decision_creators(tenant_id)
    backfill_commitment_creators(tenant_id)
  end

  def backfill_note_creators(tenant_id)
    Note.unscoped.where(tenant_id: tenant_id).find_each(batch_size: 100) do |note|
      next if note.is_comment?
      next unless note.created_by_id

      upsert_creator_status(note.tenant_id, note.created_by_id, "Note", note.id)
    rescue StandardError => e
      Rails.logger.error "Failed to backfill creator status for Note #{note.id}: #{e.message}"
    end
  end

  def backfill_decision_creators(tenant_id)
    Decision.unscoped.where(tenant_id: tenant_id).find_each(batch_size: 100) do |decision|
      next unless decision.created_by_id

      upsert_creator_status(decision.tenant_id, decision.created_by_id, "Decision", decision.id)
    rescue StandardError => e
      Rails.logger.error "Failed to backfill creator status for Decision #{decision.id}: #{e.message}"
    end
  end

  def backfill_commitment_creators(tenant_id)
    Commitment.unscoped.where(tenant_id: tenant_id).find_each(batch_size: 100) do |commitment|
      next unless commitment.created_by_id

      upsert_creator_status(commitment.tenant_id, commitment.created_by_id, "Commitment", commitment.id)
    rescue StandardError => e
      Rails.logger.error "Failed to backfill creator status for Commitment #{commitment.id}: #{e.message}"
    end
  end

  def upsert_creator_status(tenant_id, user_id, item_type, item_id)
    UserItemStatus.upsert(
      {
        id: SecureRandom.uuid,
        tenant_id: tenant_id,
        user_id: user_id,
        item_type: item_type,
        item_id: item_id,
        is_creator: true,
      },
      unique_by: [:tenant_id, :user_id, :item_type, :item_id]
    )
  end
end
