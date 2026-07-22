# typed: true

class CommentsListComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      commentable: T.any(Note, Decision, Commitment, RepresentationSession),
      current_user: T.nilable(User)
    ).void
  end
  def initialize(commentable:, current_user: nil)
    super()
    @commentable = commentable
    @current_user = current_user
  end

  private

  sig { returns(T::Array[Note]) }
  def comments
    @comments ||= @commentable.all_comments_chronological
  end

  # True when the comment replies to another comment (rather than the root
  # resource). Those get a "Replying to…" context line so the conversation
  # stays legible once every comment is shown in one flat chronological list.
  sig { params(comment: Note).returns(T::Boolean) }
  def reply?(comment)
    !(comment.commentable_type == @commentable.class.name && comment.commentable_id == @commentable.id)
  end
end
