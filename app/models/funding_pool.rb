# typed: true

# A standard collective's pooled-LLM-funding instrument. Enrolled members'
# prepaid balances fund the collective's attached agents (users with
# funding_pool_id set), one payer drawn uniformly at random per call. The
# pool never holds funds — it only routes each call's cost to a member's own
# Stripe balance. See LLMGateway::PayerResolver for the draw policy.
class FundingPool < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :collective
  belongs_to :created_by, class_name: "User"
  has_many :enrollments, class_name: "FundingPoolEnrollment", dependent: :destroy
  has_many :funded_agents, class_name: "User", dependent: nil

  validates :collective_id, uniqueness: { message: "already has a funding pool" }
  validates :member_daily_draw_cap_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :collective_is_standard, on: :create
  validate :tenant_matches_collective

  # Enroll (or re-enroll) a member. The enrollment gate — funded billing,
  # active membership, human, open pool — re-runs on reactivation, so a
  # withdrawn member whose funding lapsed cannot slip back in.
  sig { params(user: User).returns(FundingPoolEnrollment) }
  def enroll!(user)
    enrollment = enrollments.find_or_initialize_by(user: user)
    # Explicit scope: the enrollment lives in this pool's collective, not
    # whatever collective the thread happens to be scoped to.
    enrollment.tenant_id = tenant_id
    enrollment.collective_id = collective_id
    enrollment.archived_at = nil
    enrollment.save!
    enrollment
  end

  sig { void }
  def archive!
    self.archived_at = T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
  end

  sig { void }
  def unarchive!
    self.archived_at = nil
    save!
  end

  sig { returns(T::Boolean) }
  def archived?
    archived_at.present?
  end

  private

  sig { void }
  def collective_is_standard
    return if collective&.standard?

    errors.add(:collective_id, "must be a standard collective")
  end

  sig { void }
  def tenant_matches_collective
    return if collective.nil? || tenant_id == collective&.tenant_id

    errors.add(:tenant, "must match the collective's tenant")
  end
end
