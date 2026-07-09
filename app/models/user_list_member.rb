# typed: true

class UserListMember < ApplicationRecord
  extend T::Sig

  include Tracked

  belongs_to :tenant
  belongs_to :collective
  belongs_to :user_list
  belongs_to :user
  belongs_to :added_by, class_name: "User"

  validates :user_id, uniqueness: { scope: :user_list_id }
  validate  :scope_matches_list
  validate  :respects_blocks
  validate  :member_is_collective_member

  attr_readonly :tenant_id, :collective_id, :user_list_id

  # Tracked resolves the event actor via #created_by — surface our added_by
  # column under that name without a schema change.
  sig { returns(T.nilable(User)) }
  def created_by
    added_by
  end

  private

  # Reject rows whose scope drifts from the parent list's (e.g. a job with
  # stale Thread.current scope).
  sig { void }
  def scope_matches_list
    list = user_list
    return if list.nil?

    errors.add(:tenant_id, "must match the user_list's tenant") if tenant_id != list.tenant_id
    return unless collective_id != list.collective_id

    errors.add(:collective_id, "must match the user_list's collective")
  end

  # Symmetric: blocks between owner↔target or adder↔target both reject.
  sig { void }
  def respects_blocks
    list = user_list
    member = user
    return if list.nil? || member.nil?

    owner = T.must(list.owner)
    if UserBlock.between?(member, owner)
      errors.add(:user_id, "cannot be added due to a block between the owner and this user")
      return
    end

    adder = added_by
    return if adder.nil? || adder.id == member.id || adder.id == owner.id
    return unless UserBlock.between?(member, adder)

    errors.add(:user_id, "cannot be added due to a block between the adder and this user")
  end

  sig { void }
  def member_is_collective_member
    return if CollectiveMember.exists?(collective_id: collective_id, user_id: user_id)
    return if addable_collective_identity?

    errors.add(:user_id, "must be a member of the collective")
  end

  # Collective-identity users are structurally barred from *membership* in the
  # main collective — a collective can't be a member of the tenant-wide
  # "everyone" — but they're still tenant citizens you can tune in to. The
  # primary "tuned in" list is main-collective-scoped, so admit an identity
  # user there as long as its collective lives in this list's tenant. Without
  # this, tuning in to a collective identity fails validation even once the
  # request reaches the right route (issue #468).
  sig { returns(T::Boolean) }
  def addable_collective_identity?
    member = user
    list = user_list
    return false if member.nil? || list.nil?
    return false unless member.collective_identity?
    return false unless list.collective&.is_main_collective?

    Collective.where(identity_user_id: member.id, tenant_id: list.tenant_id).exists?
  end
end
