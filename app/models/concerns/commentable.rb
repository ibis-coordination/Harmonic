module Commentable
  extend ActiveSupport::Concern

  included do
    has_many :comments,
             class_name: 'Note',
             as: :commentable,
             dependent: :destroy
  end

  def is_commentable?
    true
  end

  # Get all comments for this resource
  def comments_count
    comments.count
  end

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
      tenant_id: self.tenant_id,
      studio_id: self.studio_id
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
end
