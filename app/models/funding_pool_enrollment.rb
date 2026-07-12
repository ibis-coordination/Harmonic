# typed: true

# A member's consent to fund their collective's agents from their own prepaid
# balance, one uniformly-random draw at a time. The gate below runs at
# enrollment (and re-enrollment); per-call enforcement of the same conditions
# lives in LLMGateway::PayerResolver, which must not trust an enrollment that
# was valid when it was created. Withdrawal archives the row — it is the
# consent record for draws already made.
class FundingPoolEnrollment < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :collective
  belongs_to :funding_pool
  belongs_to :user

  scope :active, -> { where(archived_at: nil) }

  before_validation :set_scope_from_pool
  validates :user_id, uniqueness: { scope: :funding_pool_id }
  # The member's own daily ceiling on this pool's draws, stated as part of the
  # consent — mandatory, so no enrollee's exposure rests on an assumed limit.
  # The effective ceiling at draw time is min(pool ceiling, this).
  validates :daily_draw_cap_cents, numericality: { only_integer: true, greater_than: 0 }
  validate :scope_matches_pool
  validate :enrollable, if: :enrolling?

  sig { void }
  def withdraw!
    self.archived_at = T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
  end

  sig { returns(T::Boolean) }
  def archived?
    archived_at.present?
  end

  private

  # Backfills scope from the pool when nothing set it. ApplicationRecord's
  # auto-population runs first and can fill collective_id from the thread
  # scope, so callers creating enrollments from another collective's context
  # must set the scope explicitly (FundingPool#enroll! does); a mismatch is a
  # validation error, not a silent correction.
  sig { void }
  def set_scope_from_pool
    pool = funding_pool
    return unless pool

    self.collective_id = pool.collective_id if collective_id.nil?
    self.tenant_id = pool.tenant_id if tenant_id.nil?
  end

  sig { void }
  def scope_matches_pool
    pool = funding_pool
    return unless pool

    errors.add(:collective, "must match the funding pool's collective") if collective_id != pool.collective_id
    errors.add(:tenant, "must match the funding pool's tenant") if tenant_id != pool.tenant_id
  end

  # The gate runs when consent is being (re)granted — on create and on
  # reactivation — never on withdrawal, which must always go through.
  sig { returns(T::Boolean) }
  def enrolling?
    new_record? || (archived_at_changed? && archived_at.nil?)
  end

  sig { void }
  def enrollable
    pool = funding_pool
    if pool.nil? || pool.archived?
      errors.add(:funding_pool_id, "is closed")
      return
    end

    enrollee = user
    if enrollee.nil? || !enrollee.human?
      errors.add(:user_id, "must be a human member — only humans can fund a pool")
      return
    end

    membership = CollectiveMember.tenant_scoped_only(pool.tenant_id)
      .find_by(collective_id: pool.collective_id, user_id: enrollee.id)
    if membership.nil? || membership.archived?
      errors.add(:user_id, "must be an active member of the pool's collective")
      return
    end

    return if enrollee.funded_billing?

    errors.add(:user_id, "requires funded billing — an active prepaid-credit subscription")
  end
end
