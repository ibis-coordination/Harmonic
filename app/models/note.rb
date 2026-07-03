# typed: true

class Note < ApplicationRecord
  extend T::Sig
  include Tracked
  include Linkable
  include Pinnable
  include Summarizable
  include HasTruncatedId
  include Attachable
  include Commentable
  include Searchable
  include InvalidatesSearchIndex
  include TracksUserItemStatus
  include HasRepresentationSessionEvents
  include SoftDeletable
  participates_in_hard_delete
  SUBTYPES = ["post", "reminder", "table", "comment", "statement", "summary"].freeze
  MAX_TITLE_LENGTH = 1000
  MAX_TEXT_LENGTH = 1_000_000

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :collective
  before_validation :set_collective_id
  belongs_to :created_by, class_name: "User"
  belongs_to :updated_by, class_name: "User"

  # Commentable pattern - allows notes to be comments on other resources
  belongs_to :commentable, polymorphic: true, optional: true

  # Statementable pattern - allows notes to be statements on statementable resources
  belongs_to :statementable, polymorphic: true, optional: true

  # Summarizable pattern - allows notes to be summaries of summarizable resources
  belongs_to :summarizable, polymorphic: true, optional: true

  # Reminder notes link to their scheduled notification
  belongs_to :reminder_notification, class_name: "Notification", optional: true

  has_many :note_history_events, dependent: :destroy
  has_many :media_items,
           -> { order(:display_order, :created_at) },
           as: :mediable,
           class_name: "MediaItem",
           dependent: :destroy
  # validates :title, presence: true
  EDIT_ACCESS_OPTIONS = ["members", "owner"].freeze

  validates :text, presence: true, unless: :is_table?
  validates :text, length: { maximum: MAX_TEXT_LENGTH }
  validate :validate_title_length
  validates :subtype, inclusion: { in: SUBTYPES }
  validates :edit_access, inclusion: { in: EDIT_ACCESS_OPTIONS }
  validate :comments_must_be_comment_subtype
  validate :statements_must_be_statement_subtype
  validate :summaries_must_be_summary_subtype
  validate :validate_table_data, if: :should_validate_table_data?

  after_create do
    NoteHistoryEvent.create!(
      note: self,
      user: created_by,
      event_type: "create",
      happened_at: created_at
    )
    # Under representation, the represented user did not actually read the
    # note — the representative did. Attribute the auto-read-confirmation
    # to whoever performed the creation. Self-acting falls through to
    # `created_by` as before.
    reader = RepresentationContext.current_representative_user || T.must(created_by)
    confirm_read!(reader)
    commentable.confirm_read!(reader) if commentable.is_a?(Note)
  end

  after_update do
    NoteHistoryEvent.create!(
      note: self,
      user: updated_by,
      event_type: "update",
      happened_at: updated_at
    )
  end

  sig { returns(T::Boolean) }
  def is_post?
    subtype == "post"
  end

  sig { returns(T::Boolean) }
  def is_reminder?
    subtype == "reminder"
  end

  sig { returns(T::Boolean) }
  def is_table?
    subtype == "table"
  end

  # Reminder logic is in NoteReminderService. These delegates keep view/controller
  # call sites concise. For multi-step operations, use reminder_service directly.
  # `reminder_scheduled_for` is a database column — no delegate needed.

  sig { returns(NoteReminderService) }
  def reminder_service
    @reminder_service ||= T.let(NoteReminderService.new(self), T.nilable(NoteReminderService))
  end

  sig { returns(T::Boolean) }
  def reminder_pending?
    is_reminder? && reminder_service.pending?
  end

  sig { returns(T::Boolean) }
  def reminder_delivered?
    is_reminder? && reminder_service.delivered?
  end

  sig { returns(T::Boolean) }
  def reminder_cancelled?
    is_reminder? && reminder_service.cancelled?
  end

  sig { returns(T::Boolean) }
  def reminder_editable?
    !is_reminder? || reminder_service.editable?
  end

  sig { params(user: User).returns(T::Boolean) }
  def user_can_edit_content?(user)
    return user_can_edit?(user) if edit_access == "owner"

    true # "members" — any authenticated user can edit content
  end

  sig { returns(String) }
  def title
    return "[deleted]" if deleted?

    persisted = super
    persisted.presence || T.must(T.must(text).split("\n").first).truncate(256)
  end

  sig { returns(T.nilable(String)) }
  def persisted_title
    attributes["title"]
  end

  # Accessor masking: when soft-deleted, the public readers return placeholders
  # even though the DB row preserves the real content for the grace period.
  # raw_* methods are the escape hatch for legitimate readers (audit snapshots,
  # undo verification, admin recovery).
  sig { returns(T.nilable(String)) }
  def raw_title
    attributes["title"]
  end

  sig { returns(T.nilable(String)) }
  def raw_text
    attributes["text"]
  end

  sig { returns(T.untyped) }
  def raw_table_data
    attributes["table_data"]
  end

  sig { returns(T.nilable(String)) }
  def text
    return "[deleted]" if deleted?

    super
  end

  sig { returns(T.untyped) }
  def table_data
    return nil if deleted?

    super
  end

  sig { returns(Integer) }
  def confirmed_reads
    @confirmed_reads ||= if note_history_events.loaded?
                           note_history_events.select { |e| e.event_type == "read_confirmation" }.map(&:user_id).uniq.count
                         else
                           note_history_events.where(event_type: "read_confirmation").select(:user_id).distinct.count
                         end
  end

  sig { returns(String) }
  def metric_name
    is_reminder? && reminder_delivered? ? "acknowledgments" : "readers"
  end

  sig { returns(Integer) }
  def metric_value
    is_reminder? && reminder_delivered? ? reminder_service.acknowledgments : confirmed_reads
  end

  sig { returns(String) }
  def octicon_metric_icon_name
    is_reminder? && reminder_delivered? ? "bell" : "book"
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      id: id,
      truncated_id: truncated_id,
      subtype: subtype,
      edit_access: edit_access,
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
      statementable_type: statementable_type,
      statementable_id: statementable_id,
      summarizable_type: summarizable_type,
      summarizable_id: summarizable_id,
      reminder_notification_id: reminder_notification_id,
      reminder_scheduled_for: reminder_scheduled_for,
    }
    response.merge!({ history_events: history_events.map(&:api_json) }) if include.include?("history_events")
    response.merge!({ backlinks: backlinks.map(&:api_json) }) if include.include?("backlinks")
    response
  end

  sig { returns(String) }
  def path_prefix
    "n"
  end

  sig { returns(ActiveRecord::Relation) }
  def history_events
    note_history_events
  end

  sig { params(user: User).returns(NoteHistoryEvent) }
  def confirm_read!(user)
    existing_confirmation = NoteHistoryEvent.find_by(
      note: self,
      user: user,
      event_type: "read_confirmation"
    )
    return existing_confirmation if existing_confirmation && T.must(existing_confirmation.happened_at) > T.must(updated_at)

    event = NoteHistoryEvent.create!(
      note: self,
      user: user,
      event_type: "read_confirmation",
      happened_at: Time.current
    )
    # Clear memoized count so it's recalculated with the new confirmation
    @confirmed_reads = nil
    # Confirming read also clears the in-app notification that pointed the user
    # here. Lives on the write path (past the idempotency early-return) so every
    # confirm-read route is covered by construction — the explicit action, and
    # the after_create auto-confirms (author's own note, and a commenter's read
    # of the parent note). Repeat confirms short-circuit above and never reach
    # this. The mark query is already a no-op when nothing is unread.
    NotificationService.mark_read_for_subject(user, tenant: T.must(tenant), subject: self)
    event
  end

  sig { params(user: User).returns(ActiveRecord::Relation) }
  def self.where_user_has_read(user:)
    joins(:note_history_events).where(note_history_events: {
                                        user: user,
                                        event_type: "read_confirmation",
                                      })
  end

  sig { params(user: User).returns(T::Boolean) }
  def user_has_read?(user)
    note_history_events.exists?(user: user,
                                event_type: "read_confirmation")
  end

  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def user_can_edit?(user)
    return false if user.nil?

    user.id == T.must(created_by).id
  end

  # Comment-related helper methods
  sig { returns(T::Boolean) }
  def is_statement?
    subtype == "statement"
  end

  sig { returns(T::Boolean) }
  def is_comment?
    subtype == "comment"
  end

  sig { returns(T::Boolean) }
  def is_summary?
    subtype == "summary"
  end

  sig { returns(T::Boolean) }
  def is_summarizable?
    !is_summary?
  end

  sig { returns(T::Boolean) }
  def has_commentable?
    commentable_type.present? && commentable_id.present?
  end

  # Override from HasRepresentationSessionEvents to differentiate comments from notes
  sig { returns(String) }
  def creation_action_name
    is_comment? ? "add_comment" : "create_note"
  end

  sig { returns(T::Boolean) }
  def has_statementable?
    statementable_type.present? && statementable_id.present?
  end

  sig { returns(T::Boolean) }
  def has_summarizable?
    summarizable_type.present? && summarizable_id.present?
  end

  sig { returns(T::Boolean) }
  def standalone_note?
    !is_comment? && !is_statement? && !is_summary?
  end

  # The non-comment ancestor this conversation is *about* — the Decision /
  # standalone Note / Commitment / etc. that the thread is rooted on. Returns
  # self for non-comments. Walks up the polymorphic `commentable` chain while
  # the parent is itself a Note (i.e. another comment).
  #
  # Result is memoized per instance. Bulk callers that already know the root
  # (e.g. Commentable#comments_with_threads) should set it via
  # `root_commentable=` after preloading to avoid the polymorphic walk
  # entirely — that's the hot path for rendering a thread.
  sig { params(root_commentable: T.untyped).void }
  attr_writer :root_commentable

  sig { returns(T.untyped) }
  def root_commentable
    return @root_commentable if defined?(@root_commentable)
    return @root_commentable = self unless is_comment? && has_commentable?

    cur = T.let(T.unsafe(self).commentable, T.untyped)
    depth = 0
    while cur.is_a?(Note) && T.unsafe(cur).is_comment? && T.unsafe(cur).has_commentable?
      cur = T.unsafe(cur).commentable
      depth += 1
      break if depth > 20 # cycle / depth guard
    end
    @root_commentable = cur
  end

  # The URL to link to when surfacing this note in a display context —
  # comment lists, mention notifications, agent task prompts. For comments,
  # returns the root commentable's path with `?comment_id=<truncated_id>` so
  # the caller lands on the full thread with this comment marked, rather
  # than the isolated /n/<comment-id> page. For non-comments, equals `path`.
  #
  # Summaries are addressed by their own canonical `/n/<id>` page just like
  # any other note; the friendly `<parent>/summary` URL is a redirect-only
  # entry point (see ApplicationController#render_summary_for), not a distinct
  # resource path. Keeping summaries on the canonical path is what makes
  # confirm/acknowledge/report and every other suffix-built action endpoint
  # resolve — overriding `path` to `<parent>/summary` is what 404'd them.
  #
  # Use `path` (not `display_path`) when building API URLs by suffix
  # concatenation (form actions, JS action endpoints, etc.) — `path` is the
  # canonical bare resource URL.
  sig { returns(T.nilable(String)) }
  def display_path
    return path unless is_comment? && has_commentable?

    root = root_commentable
    root_path = root.respond_to?(:path) ? root.path : nil
    return path if root_path.blank?

    "#{root_path}?comment_id=#{truncated_id}"
  end

  # Returns all descendants (replies, replies to replies, etc.) chronologically
  # Uses PostgreSQL recursive CTE for efficient single-query fetching
  # IMPORTANT: find_by_sql bypasses default_scope, so we must filter by tenant/collective
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
          AND notes.collective_id = :collective_id

        UNION ALL

        SELECT n.*, d.depth + 1
        FROM notes n
        INNER JOIN descendants d ON n.commentable_id = d.id
          AND n.commentable_type = 'Note'
        WHERE n.tenant_id = :tenant_id
          AND n.collective_id = :collective_id
      )
      SELECT * FROM descendants
      ORDER BY created_at ASC
    SQL

    sanitized_sql = Note.sanitize_sql_array([
                                              sql,
                                              { note_id: id, tenant_id: tenant_id, collective_id: collective_id },
                                            ])
    Note.find_by_sql(sanitized_sql)
  end

  # Preload associations for a collection of notes (avoids N+1)
  sig { params(notes: T::Array[Note]).returns(T::Array[Note]) }
  def self.preload_for_display(notes)
    ActiveRecord::Associations::Preloader.new(
      records: notes,
      associations: [:created_by, :commentable, :note_history_events,
                     { media_items: { file_attachment: :blob } },]
    ).call
    notes
  end

  # Only these commentable types are included in the search index.
  # Used by search_index_items to avoid reindexing non-searchable parents.
  SEARCHABLE_COMMENTABLE_TYPES = ["Note", "Decision", "Commitment"].freeze

  def content_snapshot
    { title: raw_title, text: raw_text }
  end

  private

  # Override from Tracked: comments are Note rows, but their events are
  # comment.* so automation rules and notification routing can distinguish
  # them from top-level notes.
  sig { returns(String) }
  def tracked_event_prefix
    is_comment? ? "comment" : "note"
  end

  def should_validate_table_data?
    is_table? && !deleted_at?
  end

  def validate_table_data
    NoteTableValidator.validate(table_data, errors)
  end

  # Validate against the raw persisted title rather than the `.title` accessor,
  # which derives a fallback from `text` and would mis-attribute length errors.
  def validate_title_length
    raw = raw_title
    return if raw.nil?
    return unless raw.length > MAX_TITLE_LENGTH

    errors.add(:title, :too_long, count: MAX_TITLE_LENGTH)
  end

  def comments_must_be_comment_subtype
    if has_commentable? && subtype != "comment"
      errors.add(:subtype, "must be comment for comments")
    elsif !has_commentable? && subtype == "comment"
      errors.add(:subtype, "cannot be comment for standalone notes")
    end
  end

  def statements_must_be_statement_subtype
    if has_statementable? && subtype != "statement"
      errors.add(:subtype, "must be statement for statementable notes")
    elsif !has_statementable? && subtype == "statement"
      errors.add(:subtype, "cannot be statement without a statementable parent")
    end
  end

  def summaries_must_be_summary_subtype
    if has_summarizable? && subtype != "summary"
      errors.add(:subtype, "must be summary for summarizable notes")
    elsif !has_summarizable? && subtype == "summary"
      errors.add(:subtype, "cannot be summary without a summarizable parent")
    end
  end

  def on_soft_delete
    reminder_service.cancel! if is_reminder? && reminder_notification_id.present?
  end

  # When a comment is created/destroyed, reindex the parent to update comment_count.
  #
  # IMPORTANT: Not all commentables are searchable. For example, RepresentationSession
  # is commentable but not included in the search index. In that case:
  # - The comment (this Note) IS indexed via the Searchable concern
  # - The parent (RepresentationSession) should NOT be reindexed here
  #
  # Only return commentables that are actually searchable (Note, Decision, Commitment).
  # Future commentable types that aren't searchable should be excluded here.
  def search_index_items
    return [] unless is_comment?
    return [] unless SEARCHABLE_COMMENTABLE_TYPES.include?(commentable_type)

    [commentable].compact
  end

  # Track the creator of this note (including comments)
  def user_item_status_updates
    return [] if created_by_id.blank?

    [
      {
        tenant_id: tenant_id,
        user_id: created_by_id,
        item_type: "Note",
        item_id: id,
        is_creator: true,
      },
    ]
  end
end
