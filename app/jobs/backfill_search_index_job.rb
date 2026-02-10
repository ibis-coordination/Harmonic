# typed: false

class BackfillSearchIndexJob < ApplicationJob
  queue_as :low_priority

  def perform(tenant_id: nil)
    Rails.logger.info "Starting search index backfill..."

    # First, clean up orphaned entries (items that no longer exist)
    cleanup_orphaned_entries(tenant_id)

    if tenant_id
      backfill_tenant(tenant_id)
    else
      Tenant.find_each { |tenant| backfill_tenant(tenant.id) }
    end

    Rails.logger.info "Search index backfill complete."
  end

  private

  def cleanup_orphaned_entries(tenant_id)
    Rails.logger.info "Cleaning up orphaned search index entries..."

    tenant_condition = tenant_id ? "AND si.tenant_id = '#{tenant_id}'" : ""

    # Delete Note entries where the note doesn't exist
    deleted_notes = ActiveRecord::Base.connection.execute(<<-SQL.squish)
      DELETE FROM search_index si
      WHERE si.item_type = 'Note'
      #{tenant_condition}
      AND NOT EXISTS (
        SELECT 1 FROM notes n WHERE n.id = si.item_id
      )
    SQL

    # Delete Decision entries where the decision doesn't exist
    deleted_decisions = ActiveRecord::Base.connection.execute(<<-SQL.squish)
      DELETE FROM search_index si
      WHERE si.item_type = 'Decision'
      #{tenant_condition}
      AND NOT EXISTS (
        SELECT 1 FROM decisions d WHERE d.id = si.item_id
      )
    SQL

    # Delete Commitment entries where the commitment doesn't exist
    deleted_commitments = ActiveRecord::Base.connection.execute(<<-SQL.squish)
      DELETE FROM search_index si
      WHERE si.item_type = 'Commitment'
      #{tenant_condition}
      AND NOT EXISTS (
        SELECT 1 FROM commitments c WHERE c.id = si.item_id
      )
    SQL

    total = deleted_notes.cmd_tuples + deleted_decisions.cmd_tuples + deleted_commitments.cmd_tuples
    Rails.logger.info "Removed #{total} orphaned search index entries" if total.positive?
  end

  def backfill_tenant(tenant_id)
    Rails.logger.info "Backfilling tenant: #{tenant_id}"

    backfill_notes(tenant_id)
    backfill_decisions(tenant_id)
    backfill_commitments(tenant_id)
    backfill_user_status(tenant_id)
  end

  def backfill_notes(tenant_id)
    Note.unscoped_for_system_job.where(tenant_id: tenant_id).find_each(batch_size: 100) do |note|
      SearchIndexer.reindex(note)
    rescue StandardError => e
      Rails.logger.error "Failed to index Note #{note.id}: #{e.message}"
    end
  end

  def backfill_decisions(tenant_id)
    Decision.unscoped_for_system_job.where(tenant_id: tenant_id).find_each(batch_size: 100) do |decision|
      SearchIndexer.reindex(decision)
    rescue StandardError => e
      Rails.logger.error "Failed to index Decision #{decision.id}: #{e.message}"
    end
  end

  def backfill_commitments(tenant_id)
    Commitment.unscoped_for_system_job.where(tenant_id: tenant_id).find_each(batch_size: 100) do |commitment|
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
    NoteHistoryEvent.unscoped_for_system_job
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
    DecisionParticipant.unscoped_for_system_job
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
    CommitmentParticipant.unscoped_for_system_job
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
    # Include both regular notes and comments (which are also Notes)
    Note.unscoped_for_system_job.where(tenant_id: tenant_id).find_each(batch_size: 100) do |note|
      next unless note.created_by_id

      upsert_creator_status(note.tenant_id, note.created_by_id, "Note", note.id)
    rescue StandardError => e
      Rails.logger.error "Failed to backfill creator status for Note #{note.id}: #{e.message}"
    end
  end

  def backfill_decision_creators(tenant_id)
    Decision.unscoped_for_system_job.where(tenant_id: tenant_id).find_each(batch_size: 100) do |decision|
      next unless decision.created_by_id

      upsert_creator_status(decision.tenant_id, decision.created_by_id, "Decision", decision.id)
    rescue StandardError => e
      Rails.logger.error "Failed to backfill creator status for Decision #{decision.id}: #{e.message}"
    end
  end

  def backfill_commitment_creators(tenant_id)
    Commitment.unscoped_for_system_job.where(tenant_id: tenant_id).find_each(batch_size: 100) do |commitment|
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
