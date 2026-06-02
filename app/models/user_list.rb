# typed: true

class UserList < ApplicationRecord
  extend T::Sig

  include HasTruncatedId
  include SoftDeletable

  VISIBILITIES = ["public", "private"].freeze

  belongs_to :tenant
  belongs_to :collective
  belongs_to :creator, class_name: "User"
  belongs_to :owner,   class_name: "User"

  has_many :user_list_members, dependent: :destroy
  has_many :members, through: :user_list_members, source: :user

  validates :name,        presence: true, length: { maximum: 80 }
  validates :description, length: { maximum: 500 }, allow_nil: true
  validates :visibility,  inclusion: { in: VISIBILITIES }
  validate  :one_primary_per_owner_per_tenant
  validate  :primary_list_is_strictly_owners

  # owner_id is intentionally mutable to support ownership transfer.
  attr_readonly :tenant_id, :collective_id, :creator_id

  sig { returns(T::Boolean) }
  def public?
    visibility == "public"
  end

  sig { returns(T::Boolean) }
  def private?
    visibility == "private"
  end

  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def visible_to?(user)
    return false if user.nil?
    return true if user.id == owner_id
    return false if private?

    coll_id = collective_id
    return false if coll_id.nil?

    CollectiveMember.exists?(collective_id: coll_id, user_id: user.id)
  end

  sig { returns(String) }
  def path_prefix
    "lists"
  end

  sig { returns(String) }
  def content_snapshot
    [name, description].compact.join("\n\n")
  end

  private

  # A user's primary list is strictly theirs: its owner cannot be transferred
  # to anyone else, and it cannot be demoted out of primary status. Custom
  # (non-primary) lists may be transferred or co-edited; the primary list
  # cannot.
  sig { void }
  def primary_list_is_strictly_owners
    return unless persisted?

    if is_primary_was && owner_id_changed?
      errors.add(:owner_id, "of a primary list cannot be transferred")
    end
    if is_primary_was && !is_primary
      errors.add(:is_primary, "of a primary list cannot be cleared")
    end
  end

  # Friendly validation companion to the partial unique index. Cross-collective
  # within the same tenant — unscopes the default collective filter.
  sig { void }
  def one_primary_per_owner_per_tenant
    return unless is_primary
    return if tenant_id.nil?

    scope = self.class
      .tenant_scoped_only(tenant_id)
      .where(owner_id: owner_id, is_primary: true, deleted_at: nil)
    scope = scope.where.not(id: id) if persisted?

    return unless scope.exists?

    errors.add(:is_primary, "another primary list already exists for this owner in this tenant")
  end
end
