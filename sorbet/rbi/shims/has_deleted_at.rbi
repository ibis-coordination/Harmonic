# typed: true

# Types for the HasDeletedAt concern (the concern itself is typed: false
# because it reads the including model's deleted_at column).
module HasDeletedAt
  sig { returns(T::Boolean) }
  def deleted?; end

  sig { params(by: T.nilable(User)).void }
  def soft_delete!(by: nil); end
end
