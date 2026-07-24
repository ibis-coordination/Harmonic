# typed: false

# The base soft-delete contract: "delete" sets deleted_at and keeps the
# row (for audit history and FK integrity). There is no restore — models
# that need one build it on top (see SoftDeletable, which extends this
# with a grace-period undo and content behaviors). Not to be confused
# with the archived_at family (CollectiveMember, FundingPool, ...),
# which is reversible deactivation, not deletion.
#
# Deliberately no default_scope here: deleted rows must stay reachable
# through belongs_to associations (e.g. run history pages load the
# deleted rule that produced a run), and tenancy scoping already
# composes in ApplicationRecord. Filter with `.not_deleted` at query
# sites instead. (SoftDeletable layers its own default_scope on top —
# content should vanish everywhere; config and credentials should not.)
module HasDeletedAt
  extend ActiveSupport::Concern

  included do
    scope :not_deleted, -> { where(deleted_at: nil) }
  end

  def deleted?
    deleted_at.present?
  end

  # Idempotent: soft-deleting a deleted row is a no-op.
  def soft_delete!(by: nil)
    return if deleted?

    transaction do
      update!({ deleted_at: Time.current }.merge(soft_delete_updates(by)))
      after_soft_delete(by)
    end
  end

  private

  # Override to fold model-specific columns into the delete update —
  # attribution (updated_by, deleted_by_id) or side effects (enabled:
  # false). Attribution columns differ per model, which is why `by` is
  # threaded through rather than written to a fixed column here.
  def soft_delete_updates(_by)
    {}
  end

  # Override for non-column side effects (search index, pins, ...).
  # Runs inside the soft_delete! transaction.
  def after_soft_delete(_by); end
end
