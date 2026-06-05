# typed: true

class UserList < ApplicationRecord
  extend T::Sig

  include HasTruncatedId
  include SoftDeletable

  VISIBILITIES = ["public", "private"].freeze
  VALID_ADD_POLICIES = ["owner_only", "self_add", "members_add", "anyone_add"].freeze

  belongs_to :tenant
  belongs_to :collective
  belongs_to :creator, class_name: "User"
  belongs_to :owner,   class_name: "User"

  has_many :user_list_members, dependent: :destroy
  has_many :members, through: :user_list_members, source: :user

  validates :name,        presence: true, length: { maximum: 80 }
  validates :description, length: { maximum: 500 }, allow_nil: true
  validates :visibility,  inclusion: { in: VISIBILITIES }
  validates :add_policy,  inclusion: { in: VALID_ADD_POLICIES }
  validate  :one_primary_per_owner_per_tenant
  validate  :primary_list_is_strictly_owners
  validate  :restricted_lists_must_be_owner_only
  validate  :tune_in_list_attributes_are_immutable

  # owner_id is intentionally mutable to support ownership transfer.
  attr_readonly :tenant_id, :collective_id, :creator_id

  # User-facing label. The stored `name` on a primary list is auto-generated
  # and never shown — viewers see "tuned in" so the list is recognizable as
  # the tune-in list rather than an ordinary custom list.
  sig { returns(String) }
  def display_name
    return "tuned in" if is_primary

    name
  end

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

  # Whether `actor` is permitted to add `target` to this list under the
  # current add_policy. Block + collective-membership checks live in
  # UserListMember validations and run on save regardless.
  sig { params(actor: T.nilable(User), target: User).returns(T::Boolean) }
  def can_add?(actor:, target:)
    return false if actor.nil?
    return true  if actor.id == owner_id

    case add_policy
    when "owner_only"
      false
    when "self_add"
      actor.id == target.id
    when "members_add"
      user_list_members.exists?(user_id: actor.id)
    when "anyone_add"
      true
    else
      false
    end
  end

  private

  # A user's primary list is strictly theirs: its owner cannot be
  # transferred, and the is_primary status is fixed at creation in both
  # directions (no demoting a primary, no promoting a custom list).
  sig { void }
  def primary_list_is_strictly_owners
    return unless persisted?

    if is_primary_was && owner_id_changed?
      errors.add(:owner_id, "of a primary list cannot be transferred")
    end
    if is_primary_changed?
      errors.add(:is_primary, "cannot be changed after a list is created")
    end
  end

  # The tune-in list is fixed at creation: its name/description/add_policy
  # are implementation details, not user-editable knobs. The display label
  # is always "tuned in" regardless of stored name (see #display_name), so
  # mutating these would only confuse the data layer without changing
  # anything a user sees. owner_id and is_primary are handled separately
  # by #primary_list_is_strictly_owners.
  sig { void }
  def tune_in_list_attributes_are_immutable
    return unless persisted?
    return unless is_primary

    errors.add(:name, "cannot be changed on the tune-in list") if name_changed?
    errors.add(:description, "cannot be changed on the tune-in list") if description_changed?
    errors.add(:add_policy, "cannot be changed on the tune-in list") if add_policy_changed?
  end

  # Primary lists and private lists are strictly the owner's domain: any
  # broader add_policy doesn't make sense (primary's social contract is
  # one user's tune-in choices, and a private list isn't visible to other
  # potential adders). Companion to the DB CHECK constraint.
  sig { void }
  def restricted_lists_must_be_owner_only
    return if add_policy == "owner_only"
    if is_primary
      errors.add(:add_policy, "must be 'owner_only' for primary lists")
    elsif private?
      errors.add(:add_policy, "must be 'owner_only' for private lists")
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
