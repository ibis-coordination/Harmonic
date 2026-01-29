# typed: true

class UserItemStatus < ApplicationRecord
  extend T::Sig

  self.table_name = "user_item_status"

  belongs_to :tenant
  belongs_to :user

  validates :item_type, inclusion: { in: ["Note", "Decision", "Commitment"] }
  validates :item_id, presence: true

  # Scopes for common filters
  scope :unread, -> { where(has_read: false) }
  scope :read, -> { where(has_read: true) }
  scope :voted, -> { where(has_voted: true) }
  scope :not_voted, -> { where(has_voted: false) }
  scope :participating, -> { where(is_participating: true) }
  scope :not_participating, -> { where(is_participating: false) }

  sig { params(tenant_id: String, user_id: String, item_type: String, item_id: String).returns(UserItemStatus) }
  def self.find_or_initialize_for(tenant_id:, user_id:, item_type:, item_id:)
    find_or_initialize_by(
      tenant_id: tenant_id,
      user_id: user_id,
      item_type: item_type,
      item_id: item_id
    )
  end

  sig { void }
  def mark_as_read!
    update!(has_read: true, read_at: Time.current)
  end

  sig { void }
  def mark_as_voted!
    update!(has_voted: true, voted_at: Time.current)
  end

  sig { void }
  def mark_as_participating!
    update!(is_participating: true, participated_at: Time.current)
  end

  sig { void }
  def mark_as_creator!
    update!(is_creator: true)
  end
end
