# typed: false

class UserBlock < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :blocker, class_name: "User"
  belongs_to :blocked, class_name: "User"

  validates :blocked_id, uniqueness: { scope: [:blocker_id, :tenant_id] }
  validate :cannot_block_yourself
  validate :cannot_block_own_agent

  after_create :clear_mutual_primary_list_memberships

  sig { params(user_a: User, user_b: User).returns(T::Boolean) }
  def self.between?(user_a, user_b)
    where(blocker: user_a, blocked: user_b)
      .or(where(blocker: user_b, blocked: user_a))
      .exists?
  end

  private

  sig { void }
  def clear_mutual_primary_list_memberships
    [[blocker_id, blocked_id], [blocked_id, blocker_id]].each do |owner_id, member_id|
      list = UserList
        .tenant_scoped_only(tenant_id)
        .where(owner_id: owner_id, is_primary: true, deleted_at: nil)
        .first
      next unless list

      list.user_list_members.where(user_id: member_id).destroy_all
    end
  end

  sig { void }
  def cannot_block_yourself
    if blocker_id == blocked_id
      errors.add(:blocked_id, "cannot block yourself")
    end
  end

  sig { void }
  def cannot_block_own_agent
    return unless blocker_id && blocked_id

    blocker_user = blocker
    blocked_user = blocked

    if blocked_user&.parent_id == blocker_id
      errors.add(:blocked_id, "cannot block your own agent")
    elsif blocker_user&.parent_id == blocked_id
      errors.add(:blocker_id, "agents cannot block their parent user")
    end
  end
end
