# typed: false

# Tracked concern - records events when content is created, updated, or deleted.
# Uses EventService to create Event records that can trigger notifications and webhooks.
module Tracked
  extend ActiveSupport::Concern

  included do
    after_create_commit :track_creation
    after_update_commit :track_changes
    after_destroy_commit :track_deletion
  end

  class_methods do
    def is_tracked?
      true
    end
  end

  private

  def track_creation
    EventService.record!(
      event_type: "#{self.class.name.underscore}.created",
      actor: respond_to?(:created_by) ? created_by : nil,
      subject: self,
      metadata: trackable_metadata_for_create
    )
  end

  def track_changes
    return if saved_changes.except("updated_at").empty?

    EventService.record!(
      event_type: "#{self.class.name.underscore}.updated",
      actor: respond_to?(:updated_by) ? updated_by : nil,
      subject: self,
      metadata: { changes: saved_changes.except("updated_at") }
    )
  end

  def track_deletion
    EventService.record!(
      event_type: "#{self.class.name.underscore}.deleted",
      actor: nil,
      subject: self,
      metadata: trackable_metadata_for_delete
    )
  end

  def trackable_metadata_for_create
    base = {}
    base[:truncated_id] = truncated_id if respond_to?(:truncated_id)
    base[:text] = text.to_s.truncate(500) if respond_to?(:text) && text.present?
    base[:title] = title.to_s.truncate(200) if respond_to?(:title) && respond_to?(:persisted_title) && persisted_title.present?
    base[:name] = name if respond_to?(:name) && name.present?
    base
  end

  def trackable_metadata_for_delete
    trackable_metadata_for_create
  end
end
