class NoteHistoryEvent < ApplicationRecord
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :note
  belongs_to :user
  validates :event_type, presence: true, inclusion: { in: %w(create update read_confirmation) }
  validates :happened_at, presence: true
  validate :validate_tenant_and_studio_id

  def set_tenant_id
    self.tenant_id ||= note.tenant_id
  end

  def set_studio_id
    self.studio_id ||= note.studio_id
  end

  def validate_tenant_and_studio_id
    if note.tenant_id != tenant_id
      errors.add(:tenant_id, "must match the tenant of the note")
    end
    if note.studio_id != studio_id
      errors.add(:studio_id, "must match the studio of the note")
    end
  end

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

  def creator
    user
  end
end