# typed: true

class CommentComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      comment: Note,
      show_reply_context: T::Boolean,
      root_comment_id: String,
      show_reply_button: T::Boolean,
      current_user: T.nilable(User),
      blocked_user_ids: T::Set[String]
    ).void
  end
  def initialize(comment:, show_reply_context:, root_comment_id:, show_reply_button: true, current_user: nil, blocked_user_ids: Set.new)
    super()
    @comment = comment
    @show_reply_context = show_reply_context
    @root_comment_id = root_comment_id
    @show_reply_button = show_reply_button
    @current_user = current_user
    @blocked_user_ids = blocked_user_ids
  end

  sig { returns(T::Boolean) }
  def author_blocked?
    a = author
    a.present? && @blocked_user_ids.include?(a.id)
  end

  private

  sig { returns(T.nilable(User)) }
  def author
    @comment.created_by
  end

  sig { returns(T.nilable(User)) }
  def representative
    @comment.respond_to?(:representative_user) ? @comment.representative_user : nil
  end

  sig { returns(T::Boolean) }
  def representation?
    !!(@comment.respond_to?(:created_via_representation?) &&
      @comment.created_via_representation? &&
      representative.present?)
  end

  sig { returns(T.nilable(User)) }
  def display_author
    representation? ? representative : author
  end

  sig { returns(T::Boolean) }
  def show_task_run_link?
    a = author
    a.present? && a.ai_agent? && a.parent == @current_user
  end

  sig { returns(T.nilable(AiAgentTaskRun)) }
  def task_run
    return nil unless show_task_run_link?

    AiAgentTaskRunResource.task_run_for(@comment)
  end

  sig { returns(T::Boolean) }
  def has_reply_context?
    @show_reply_context && @comment.commentable_type == "Note" && @comment.commentable.present?
  end

  sig { returns(T::Boolean) }
  def confirmed?
    @current_user.present? && @comment.user_has_read?(@current_user)
  end
end
