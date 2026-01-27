# typed: true

class Note < ApplicationRecord
  extend T::Sig
  include Tracked
  include Linkable
  include Pinnable
  include HasTruncatedId
  include Attachable
  include Commentable
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :created_by, class_name: 'User', foreign_key: 'created_by_id'
  belongs_to :updated_by, class_name: 'User', foreign_key: 'updated_by_id'

  # Commentable pattern - allows notes to be comments on other resources
  belongs_to :commentable, polymorphic: true, optional: true

  has_many :note_history_events, dependent: :destroy
  # validates :title, presence: true

  after_create do
    NoteHistoryEvent.create!(
      note: self,
      user: self.created_by,
      event_type: 'create',
      happened_at: self.created_at,
    )
  end

  after_update do
    NoteHistoryEvent.create!(
      note: self,
      user: self.updated_by,
      event_type: 'update',
      happened_at: self.updated_at
    )
  end

  sig { returns(String) }
  def title
    persisted = super
    if persisted.nil? || persisted.empty?
      T.must(T.must(text).split("\n").first).truncate(256)
    else
      persisted
    end
  end

  sig { returns(T.nilable(String)) }
  def persisted_title
    attributes['title']
  end

  sig { returns(Integer) }
  def confirmed_reads
    @confirmed_reads ||= note_history_events.where(event_type: 'read_confirmation').select(:user_id).distinct.count
  end

  sig { returns(String) }
  def metric_name
    'readers'
  end

  sig { returns(Integer) }
  def metric_value
    confirmed_reads
  end

  sig { returns(String) }
  def octicon_metric_icon_name
    'book'
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      id: id,
      truncated_id: truncated_id,
      title: title,
      text: text,
      deadline: deadline,
      confirmed_reads: confirmed_reads,
      created_at: created_at,
      updated_at: updated_at,
      created_by_id: created_by_id,
      updated_by_id: updated_by_id,
      commentable_type: commentable_type,
      commentable_id: commentable_id,
    }
    if include.include?('history_events')
      response.merge!({ history_events: history_events.map(&:api_json) })
    end
    if include.include?('backlinks')
      response.merge!({ backlinks: backlinks.map(&:api_json)})
    end
    response
  end

  sig { returns(String) }
  def path_prefix
    'n'
  end

  sig { returns(ActiveRecord::Relation) }
  def history_events
    note_history_events
  end

  sig { returns(Integer) }
  def interaction_count
    note_history_events.count - 1 # subtract the create event
  end

  sig { params(user: User).returns(NoteHistoryEvent) }
  def confirm_read!(user)
    existing_confirmation = NoteHistoryEvent.find_by(
      note: self,
      user: user,
      event_type: 'read_confirmation'
    )
    if existing_confirmation && T.must(existing_confirmation.happened_at) > T.must(self.updated_at)
      return existing_confirmation
    else
      NoteHistoryEvent.create!(
        note: self,
        user: user,
        event_type: 'read_confirmation',
        happened_at: Time.current
      )
    end
  end

  sig { params(user: User).returns(ActiveRecord::Relation) }
  def self.where_user_has_read(user:)
    self.joins(:note_history_events).where(note_history_events: {
      user: user,
      event_type: 'read_confirmation'
    })
  end

  sig { params(user: User).returns(T::Boolean) }
  def user_has_read?(user)
    note_history_events.where(
      user: user,
      event_type: 'read_confirmation'
    ).exists?
  end

  sig { params(user: User).returns(T::Boolean) }
  def creator_can_skip_confirm?(user)
    # This is a reversed design choice to allow the creator to confirm their own note
    false
  end

  sig { params(user: User).returns(T::Boolean) }
  def user_can_edit?(user)
    user.id == T.must(created_by).id
  end

  # Comment-related helper methods
  sig { returns(T::Boolean) }
  def is_comment?
    commentable_type.present? && commentable_id.present?
  end

  sig { returns(T::Boolean) }
  def standalone_note?
    !is_comment?
  end

  # Returns all descendants (replies, replies to replies, etc.) chronologically
  # Uses PostgreSQL recursive CTE for efficient single-query fetching
  # IMPORTANT: find_by_sql bypasses default_scope, so we must filter by tenant/superagent
  sig { returns(T::Array[Note]) }
  def all_descendants
    return [] unless persisted?

    sql = <<~SQL.squish
      WITH RECURSIVE descendants AS (
        SELECT notes.*, 1 as depth
        FROM notes
        WHERE notes.commentable_id = :note_id
          AND notes.commentable_type = 'Note'
          AND notes.tenant_id = :tenant_id
          AND notes.superagent_id = :superagent_id

        UNION ALL

        SELECT n.*, d.depth + 1
        FROM notes n
        INNER JOIN descendants d ON n.commentable_id = d.id
          AND n.commentable_type = 'Note'
        WHERE n.tenant_id = :tenant_id
          AND n.superagent_id = :superagent_id
      )
      SELECT * FROM descendants
      ORDER BY created_at ASC
    SQL

    sanitized_sql = Note.sanitize_sql_array([
      sql,
      { note_id: id, tenant_id: tenant_id, superagent_id: superagent_id },
    ])
    Note.find_by_sql(sanitized_sql)
  end

  # Preload associations for a collection of notes (avoids N+1)
  sig { params(notes: T::Array[Note]).returns(T::Array[Note]) }
  def self.preload_for_display(notes)
    ActiveRecord::Associations::Preloader.new(
      records: notes,
      associations: [:created_by, :commentable]
    ).call
    notes
  end
end