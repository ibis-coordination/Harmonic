# typed: true

class StatementEmbedComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      statement: Note,
      current_user: T.nilable(User),
    ).void
  end
  def initialize(statement:, current_user: nil)
    super()
    @statement = statement
    @current_user = current_user
  end

  sig { returns(T::Boolean) }
  def render?
    @statement.is_statement?
  end

  private

  sig { returns(User) }
  def author
    T.must(@statement.created_by)
  end

  sig { returns(T::Boolean) }
  def updated?
    @statement.updated_at > @statement.created_at + 1.minute
  end

  sig { returns(String) }
  def verb
    updated? ? "updated this statement" : "added this statement"
  end

  sig { returns(T::Boolean) }
  def user_has_read?
    return false unless @current_user
    @statement.user_has_read?(@current_user)
  end

  sig { returns(Integer) }
  def read_count
    @statement.confirmed_reads
  end

  def read_confirmations_scope
    @statement.note_history_events.where(event_type: "read_confirmation")
  end
end
