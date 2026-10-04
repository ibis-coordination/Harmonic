# typed: true

# Creates an AI agent for a human principal and settles the agent's billing
# state. Callers pass an ApiHelper built with the principal as current_user
# and the creation params (name, handle, mode, capabilities, ...), then render
# their own response from the Result.
#
# Statuses:
#   :created                        — the agent exists. `charged_cents` is set
#                                     when the subscription sync charged a
#                                     proration. The agent may still be
#                                     pending_billing_setup.
#   :billing_setup_required         — the principal must set up billing first.
#   :billing_confirmation_required  — billing is on and the principal has not
#                                     confirmed the per-agent charge.
#   :handle_taken                   — an explicitly chosen handle is in use.
#
# Nothing is created for any status other than :created.
class AiAgentCreationService
  extend T::Sig

  class Result < T::Struct
    const :status, Symbol
    const :ai_agent, T.nilable(User), default: nil
    const :charged_cents, T.nilable(Integer), default: nil

    def created?
      status == :created
    end
  end

  sig { params(api_helper: ApiHelper, billing_confirmed: T::Boolean).returns(Result) }
  def self.call(api_helper:, billing_confirmed:)
    new(api_helper: api_helper, billing_confirmed: billing_confirmed).call
  end

  sig { params(api_helper: ApiHelper, billing_confirmed: T::Boolean).void }
  def initialize(api_helper:, billing_confirmed:)
    @api_helper = api_helper
    @principal = T.let(api_helper.current_user, User)
    @tenant = T.let(api_helper.current_tenant, Tenant)
    @billing_confirmed = billing_confirmed
  end

  sig { returns(Result) }
  def call
    return Result.new(status: :billing_setup_required) if @principal.requires_stripe_billing?(@tenant)
    return Result.new(status: :billing_confirmation_required) if billing_confirmation_missing?

    begin
      # requires_new: a failed handle must roll back the half-built agent even
      # when the caller has its own transaction open. Without the savepoint
      # the user row would survive in the caller's transaction.
      ai_agent = ActiveRecord::Base.transaction(requires_new: true) { @api_helper.create_ai_agent }
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # An explicitly-chosen handle that's already taken (or reserved) fails:
      # the uniqueness validation raises RecordInvalid, with the DB index as
      # the race backstop (RecordNotUnique). A blank handle auto-generates and
      # never reaches here. Re-raise any unrelated validation failure rather
      # than mislabeling it as a handle problem.
      raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.key?(:handle)

      return Result.new(status: :handle_taken)
    end

    Result.new(status: :created, ai_agent: ai_agent, charged_cents: settle_billing!(ai_agent))
  end

  private

  # Admins (sys_admin / app_admin) are billing-exempt — they never see the
  # confirm-billing checkbox in the UI, so don't reject them for not
  # checking it.
  sig { returns(T::Boolean) }
  def billing_confirmation_missing?
    @tenant.feature_enabled?("stripe_billing") &&
      !@principal.app_admin? && !@principal.sys_admin? &&
      !@billing_confirmed
  end

  # Returns the prorated charge in cents, if the subscription sync made one.
  sig { params(ai_agent: User).returns(T.nilable(Integer)) }
  def settle_billing!(ai_agent)
    return nil unless @tenant.feature_enabled?("stripe_billing")

    stripe_customer = @principal.stripe_customer
    ai_agent.update!(stripe_customer_id: stripe_customer.id) if stripe_customer

    # Decide whether the new agent needs to wait for billing setup.
    # Use requires_stripe_billing? rather than stripe_customer.active?
    # so admins (who are billing-exempt — billable_quantity is always 0)
    # don't get their agents spuriously pending-flagged.
    if @principal.requires_stripe_billing?(@tenant)
      ai_agent.update!(pending_billing_setup: true)
    elsif @principal.stripe_customer&.active?
      result = StripeService.sync_subscription_quantity!(@principal)
      return result.charged_cents if result.success

      # Sync failed — mark agent pending so it doesn't run unbilled
      ai_agent.update!(pending_billing_setup: true)
    end
    # Else: principal doesn't need billing (admin / fully exempt) — leave the agent active.
    nil
  end
end
