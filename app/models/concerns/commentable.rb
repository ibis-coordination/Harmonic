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
      created_by: created_by,
      updated_by: created_by,
      tenant_id: tenant_id,
      superagent_id: superagent_id
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

  # Returns top-level comments with their descendants preloaded
  # Returns a hash with :top_level array and :threads hash mapping comment_id => descendants
  def comments_with_threads
    top_level = chronological_comments.to_a

    # Build a hash of comment_id => descendants for efficient lookup
    threads = {}
    top_level.each do |comment|
      descendants = comment.all_descendants
      Note.preload_for_display(descendants)
      threads[comment.id] = descendants
    end

    { top_level: top_level, threads: threads }
  end
end
