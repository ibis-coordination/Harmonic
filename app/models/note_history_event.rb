# typed: true

class NoteHistoryEvent < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :note
  belongs_to :user
  validates :event_type, presence: true, inclusion: { in: %w(create update read_confirmation) }
  validates :happened_at, presence: true
  validate :validate_tenant_and_superagent_id

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(note).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_superagent_id
    self.superagent_id = T.must(note).superagent_id if superagent_id.nil?
  end

  sig { void }
  def validate_tenant_and_superagent_id
    if T.must(note).tenant_id != tenant_id
      errors.add(:tenant_id, "must match the tenant of the note")
    end
    if T.must(note).superagent_id != superagent_id
      errors.add(:superagent_id, "must match the superagent of the note")
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
end