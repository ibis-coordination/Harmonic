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

  # How many of a period's windows a rolling 30-day span can touch, rounded up
  # to whole windows: 30 days, ~5 weeks (30 / 7), or 2 calendar months (a
  # 30-day span straddles one boundary). Used to translate a ceiling into a
  # 30-day maximum draw.
  WINDOWS_PER_30_DAYS = { "day" => 30, "week" => 5, "month" => 2 }.freeze

  before_validation :set_scope_from_pool
  validates :user_id, uniqueness: { scope: :funding_pool_id }
  # The member's own ceiling on this pool's draws, stated as part of the
  # consent — mandatory, so no enrollee's exposure rests on an assumed limit.
  # Enforced at draw time independently of the pool's own ceiling, each over
  # its own period window.
  validates :draw_cap_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :draw_cap_period, inclusion: { in: FundingPool::DRAW_CAP_PERIODS }
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

  # The most this ceiling could allow to be drawn in a 30-day window: the
  # ceiling times the number of its windows a 30-day span can touch.
  sig { returns(Integer) }
  def draw_cap_per_30_days_cents
    draw_cap_cents * WINDOWS_PER_30_DAYS.fetch(draw_cap_period)
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

    errors.add(:user_id, "requires funded billing — a prepaid-credit subscription (top up at /billing)")
  end
end
