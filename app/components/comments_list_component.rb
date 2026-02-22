# typed: true

class CommentsListComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      commentable: T.any(Note, Decision, Commitment, RepresentationSession),
      current_user: T.nilable(User),
      studio_path: String
    ).void
  end
  def initialize(commentable:, current_user: nil, studio_path: "")
    super()
    @commentable = commentable
    @current_user = current_user
    @studio_path = studio_path
  end

  private

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def comment_data
    @comment_data ||= @commentable.comments_with_threads
  end

  sig { returns(T::Array[Note]) }
  def top_level_comments
    comment_data[:top_level]
  end

  sig { returns(T::Hash[Integer, T::Array[Note]]) }
  def threads
    comment_data[:threads]
  end
end
