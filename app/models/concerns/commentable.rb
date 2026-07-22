# typed: false

module Commentable
  extend ActiveSupport::Concern

  included do
    has_many :comments,
             class_name: "Note",
             as: :commentable,
             dependent: :destroy
  end

  def is_commentable?
    true
  end

  # Get all comments for this resource
  delegate :count, to: :comments, prefix: true

  def comment_count
    comments_count
  end

  # Check if this resource has any comments
  def has_comments?
    comments.exists?
  end

  # Add a comment to this resource
  def add_comment(text:, created_by:, title: nil)
    comments.create!(
      text: text,
      title: title,
      subtype: "comment",
      created_by: created_by,
      updated_by: created_by,
      tenant_id: tenant_id,
      collective_id: collective_id,
      deadline: Time.current
    )
  end

  # Get comments ordered by creation date (newest first)
  def recent_comments(limit: nil)
    scope = comments.includes(:created_by).order(created_at: :desc)
    limit ? scope.limit(limit) : scope
  end

  # Get comments ordered by creation date (oldest first)
  def chronological_comments
    comments.includes(:created_by).order(created_at: :asc)
  end

  # Every comment on this resource — top-level and replies of any depth —
  # flattened into a single chronological list, fetched in one query. This is
  # the flat "chat" rendering of a thread; reply relationships are still
  # carried on each comment's `commentable` pointer for "Replying to…" context.
  #
  # Memoized per instance so a single render (section header count + list) does
  # one fetch, not two.
  #
  # A soft-deleted comment is hidden, but its non-deleted replies are kept —
  # they surface with a "Replying to @handle [deleted]" context line. So we
  # fetch the whole tree (deleted included) to resolve parents, then return
  # only the non-deleted comments for display.
  def all_comments_chronological
    @all_comments_chronological ||= begin
      tree = Note.comment_tree_for(self)
      Note.preload_for_display(tree)
      by_id = tree.index_by(&:id)
      tree.each do |c|
        # Inject the root so render-time `comment.path` / `comment.root_commentable`
        # don't walk the polymorphic chain.
        c.root_commentable = self
        # Resolve the parent from the loaded set (incl. deleted parents, which
        # the not_deleted-scoped `commentable` association can't return).
        c.thread_parent = by_id[c.commentable_id] if c.commentable_type == "Note"
      end
      tree.reject(&:deleted?)
    end
  end

  # Returns top-level comments with their descendants, grouped for threaded
  # rendering. Built from the single flat fetch above (no per-thread queries):
  # :top_level is the chronological top-level comments and :threads maps each
  # top-level comment's id to its descendants (of any depth), chronologically.
  def comments_with_threads
    all = all_comments_chronological
    by_id = all.index_by(&:id)
    is_top_level = ->(c) { c.commentable_id == id && c.commentable_type == self.class.name }

    top_level = all.select { |c| is_top_level.call(c) }
    threads = top_level.each_with_object({}) { |c, h| h[c.id] = [] }

    all.each do |comment|
      next if is_top_level.call(comment)

      # Walk up to the top-level ancestor through the already-loaded set.
      ancestor = comment
      ancestor = by_id[ancestor.commentable_id] until ancestor.nil? || is_top_level.call(ancestor)
      threads[ancestor.id] << comment if ancestor
    end

    { top_level: top_level, threads: threads }
  end
end
