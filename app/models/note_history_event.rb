# typed: true

class NoteHistoryEvent < ApplicationRecord
  extend T::Sig

  include InvalidatesSearchIndex
  include TracksUserItemStatus
  include HasRepresentationSessionEvents

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :collective
  before_validation :set_collective_id
  belongs_to :note
  belongs_to :user
  validates :event_type, presence: true, inclusion: { in: %w(create update read_confirmation) }
  validates :happened_at, presence: true
  validate :validate_tenant_and_collective_id

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(note).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_collective_id
    self.collective_id = T.must(note).collective_id if collective_id.nil?
  end

  sig { void }
  def validate_tenant_and_collective_id
    if T.must(note).tenant_id != tenant_id
      errors.add(:tenant_id, "must match the tenant of the note")
    end
    if T.must(note).collective_id != collective_id
      errors.add(:collective_id, "must match the collective of the note")
    end
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      id: id,
      note_id: note_id,
      user_id: user_id,
      event_type: event_type,
      description: description,
      happened_at: happened_at,
    }
  end

  sig { returns(String) }
  def description
    # TODO refactor this
    case event_type
    when 'create'
      'created this note'
    when 'update'
      'updated this note'
    when 'read_confirmation'
      "confirmed reading this note"
    else
      raise 'Unknown event type'
    end
  end

  sig { returns(T.nilable(User)) }
  def creator
    user
  end

  private

  # Only read_confirmation events affect the search index (reader_count)
  # Note create/update events don't change reader_count
  def search_index_items
    return [] unless event_type == "read_confirmation"

    [note].compact
  end

  # Track when a user confirms reading a note
  def user_item_status_updates
    return [] unless event_type == "read_confirmation"
    return [] if user_id.blank?

    [
      {
        tenant_id: tenant_id,
        user_id: user_id,
        item_type: "Note",
        item_id: note_id,
        has_read: true,
        read_at: happened_at,
      },
    ]
  end
end
