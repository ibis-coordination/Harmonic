# typed: false

# Grace-period soft delete.
#
# soft_delete! is metadata-only — sets deleted_at, deleted_by_id, and
# hard_delete_after — and removes the row from the search index and any
# collective pins. It does NOT touch column values; defense-in-depth comes
# from accessor masking on each model (Note#title etc. return "[deleted]"
# when deleted? is true).
#
# Attachments are preserved during the grace period and purged by the
# HardDeleteExpiredRecordsJob when the row is destroyed.
#
# undo_delete! restores visibility by clearing the timestamps and re-adds
# the row to the search index. It refuses to act after hard_delete_after
# has passed (the row should already be gone by then).
module SoftDeletable
  extend ActiveSupport::Concern

  DEFAULT_GRACE_PERIOD = 30.days

  class GracePeriodExpired < StandardError; end

  included do
    scope :not_deleted, -> { where(deleted_at: nil) }
    scope :with_deleted, -> { unscope(where: :deleted_at) }
    default_scope { not_deleted }

    belongs_to :deleted_by, class_name: "User", optional: true
  end

  class_methods do
    # Opt this model into the automatic hard-delete pipeline. Models that opt in
    # get hard_delete_after set on soft_delete!, and undo_delete! refuses once the
    # grace period has passed. Models that don't opt in soft-delete forever and
    # can be undone at any time.
    def participates_in_hard_delete
      @participates_in_hard_delete = true
    end

    def participates_in_hard_delete?
      @participates_in_hard_delete == true
    end
  end

  def soft_delete!(by:)
    transaction do
      now = Time.current
      updates = { deleted_at: now, deleted_by_id: by.id }
      updates[:hard_delete_after] = now + DEFAULT_GRACE_PERIOD if self.class.participates_in_hard_delete?
      update!(updates)
      SearchIndexer.delete(self) if respond_to?(:delete_from_search_index, true)
      collective.unpin_item!(self) if respond_to?(:collective) && collective.respond_to?(:has_pinned?) && collective.has_pinned?(self)
      on_soft_delete if respond_to?(:on_soft_delete, true)
    end
  end

  def undo_delete!(by:)
    return unless deleted?
    if self.class.participates_in_hard_delete? && hard_delete_after.present? && hard_delete_after <= Time.current
      raise GracePeriodExpired, "#{self.class.name}##{id} grace period has expired"
    end
    transaction do
      updates = { deleted_at: nil, deleted_by_id: nil }
      updates[:hard_delete_after] = nil if self.class.column_names.include?("hard_delete_after")
      update!(updates)
      SearchIndexer.reindex(self) if respond_to?(:delete_from_search_index, true)
    end
  end

  def deleted?
    deleted_at.present?
  end

  # True once the row has been finalized (content nulled, row preserved).
  # Only meaningful for models with a tombstoned_at column.
  def tombstoned?
    return false unless self.class.column_names.include?("tombstoned_at")
    self[:tombstoned_at].present?
  end

  # Override in each model to return a hash of text fields for audit logging
  # and abuse-report snapshots. Should read via raw_* so it returns real
  # content even when called on a soft-deleted record.
  def content_snapshot
    raise NotImplementedError, "#{self.class.name} must implement #content_snapshot"
  end
end
