# typed: false

module SoftDeletable
  extend ActiveSupport::Concern

  included do
    scope :not_deleted, -> { where(deleted_at: nil) }
    scope :with_deleted, -> { unscope(where: :deleted_at) }
    default_scope { not_deleted }

    belongs_to :deleted_by, class_name: "User", optional: true
  end

  def soft_delete!(by:)
    transaction do
      scrub_content!
      update!(
        deleted_at: Time.current,
        deleted_by_id: by.id
      )
      # Remove from search index
      SearchIndexer.delete(self) if respond_to?(:delete_from_search_index, true)
      # Purge attachments
      attachments.destroy_all if respond_to?(:attachments)
      # Unpin from collective (pins are stored in settings JSON, not a separate model)
      collective.unpin_item!(self) if respond_to?(:collective) && collective.respond_to?(:has_pinned?) && collective.has_pinned?(self)
    end
  end

  def deleted?
    deleted_at.present?
  end

  # Override in each model to return a hash of text fields for audit logging
  def content_snapshot
    raise NotImplementedError, "#{self.class.name} must implement #content_snapshot"
  end

  private

  # Override in each model to set text fields to "[deleted]"
  def scrub_content!
    raise NotImplementedError, "#{self.class.name} must implement #scrub_content!"
  end
end
