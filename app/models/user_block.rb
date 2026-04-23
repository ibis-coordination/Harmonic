# typed: false

class UserBlock < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :blocker, class_name: "User"
  belongs_to :blocked, class_name: "User"

  validates :blocked_id, uniqueness: { scope: [:blocker_id, :tenant_id] }
  validate :cannot_block_yourself

  sig { params(user_a: User, user_b: User).returns(T::Boolean) }
  def self.between?(user_a, user_b)
    where(blocker: user_a, blocked: user_b)
      .or(where(blocker: user_b, blocked: user_a))
      .exists?
  end

  private

  sig { void }
  def cannot_block_yourself
    if blocker_id == blocked_id
      errors.add(:blocked_id, "cannot block yourself")
    end
  end
end
