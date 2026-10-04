# typed: true

# An external agent's request to join a tenant, naming the member who will be
# their human principal. The agent starts the signup unauthenticated; the
# named member claims it while logged in; the agent then collects an MCP
# token. No User row exists for the agent until the claim.
#
# Three credentials, each with a different holder:
#   * `public_id`     — in the claim URL (emailed to the principal and shown
#                       by the agent). Identifies the signup; grants nothing.
#   * poll secret     — returned only to the agent at start. Authorizes
#                       status polling and the token pickup.
#   * pairing code    — returned only to the agent at start. The principal
#                       types it on the claim page, which ties the claim to
#                       an agent the principal is actually in contact with.
# Only digests of the last two are stored.
#
# Lifecycle:
#   * `AgentSignup.start!` — creates a `pending` signup. `principal_user` is
#     set only when the email belongs to an eligible member; otherwise the row
#     is unclaimable, and exists so the agent-facing responses are identical
#     either way.
#   * `#claim!` — the principal accepted and the agent was created. Restarts
#     the expiry clock for the pickup.
#   * `#decline!` — the principal refused.
#   * `#pick_up!` — the agent collected their MCP token; the signup is
#     `redeemed`.
#
# Expiry is derived from `expires_at`, never stored as a state. A pairing-code
# lockout and supersession by a newer signup both end a signup by setting
# `expires_at` to now.
class AgentSignup < ApplicationRecord
  extend T::Sig

  class NotClaimable < StandardError; end

  STATES = T.let(["pending", "claimed", "redeemed", "declined"].freeze, T::Array[String])

  PENDING_LIFETIME = T.let(24.hours, ActiveSupport::Duration)
  PICKUP_LIFETIME = T.let(24.hours, ActiveSupport::Duration)
  MAX_PAIRING_ATTEMPTS = 5
  MAX_PENDING_PER_PRINCIPAL = 3
  MAX_NAME_LENGTH = 100
  MAX_HANDLE_LENGTH = 50
  PAIRING_CODE_DIGITS = 6

  belongs_to :tenant
  belongs_to :principal_user, class_name: "User", optional: true
  belongs_to :ai_agent_user, class_name: "User", optional: true
  belongs_to :api_token, optional: true

  # Plaintext credentials, available only on the instance `start!` returns.
  attr_accessor :poll_secret, :pairing_code

  validates :public_id, presence: true, uniqueness: { scope: :tenant_id }
  validates :poll_secret_digest, :pairing_code_digest, :expires_at, presence: true
  validates :proposed_name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validates :proposed_handle, length: { maximum: MAX_HANDLE_LENGTH }
  validates :state, inclusion: { in: STATES }

  before_validation :assign_credentials, on: :create
  before_validation :assign_expires_at, on: :create

  scope :open_pending, -> { where(state: "pending").where("expires_at > ?", Time.current) }

  sig do
    params(
      tenant: Tenant,
      principal_email: T.nilable(String),
      name: T.nilable(String),
      handle: T.nilable(String)
    ).returns(AgentSignup)
  end
  def self.start!(tenant:, principal_email:, name:, handle: nil)
    principal = eligible_principal(tenant: tenant, email: principal_email)

    transaction do
      signup = create!(
        tenant: tenant,
        principal_user: principal,
        proposed_name: name.to_s.strip,
        proposed_handle: handle.to_s.strip.presence
      )
      expire_pending_beyond_cap!(tenant: tenant, principal: principal) if principal
      signup
    end
  end

  # The member the email belongs to, if they can be a human principal on this
  # tenant right now: a human, a member, with a verified email, not suspended
  # and not on the way out.
  sig { params(tenant: Tenant, email: T.nilable(String)).returns(T.nilable(User)) }
  def self.eligible_principal(tenant:, email:)
    normalized = email.to_s.strip.downcase
    return nil if normalized.blank?

    candidates = User.where("LOWER(email) = ?", normalized).limit(2).to_a
    return nil unless candidates.size == 1

    user = T.must(candidates.first)
    return nil unless eligible_principal?(user, tenant: tenant)

    user
  end

  sig { params(user: User, tenant: Tenant).returns(T::Boolean) }
  def self.eligible_principal?(user, tenant:)
    user.human? &&
      user.email_verified? &&
      !user.suspended? &&
      user.deletion_requested_at.nil? &&
      tenant.tenant_users.exists?(user: user)
  end

  sig { params(tenant: Tenant, principal: User).void }
  def self.expire_pending_beyond_cap!(tenant:, principal:)
    surplus_ids = tenant_scoped_only(tenant.id)
      .open_pending
      .where(principal_user_id: principal.id)
      .order(created_at: :desc)
      .offset(MAX_PENDING_PER_PRINCIPAL)
      .pluck(:id)
    return if surplus_ids.empty?

    tenant_scoped_only(tenant.id).where(id: surplus_ids).update_all(expires_at: Time.current)
  end

  sig { returns(String) }
  def claim_url
    "#{T.must(tenant).url}/agent-signups/#{public_id}/claim"
  end

  sig { returns(String) }
  def status_url
    "#{T.must(tenant).url}/agent-signups/#{public_id}/status"
  end

  sig { returns(T::Boolean) }
  def expired?
    expires_at <= Time.current
  end

  sig { returns(T::Boolean) }
  def pending?
    state == "pending"
  end

  sig { returns(T::Boolean) }
  def claimed?
    state == "claimed"
  end

  sig { params(candidate: T.nilable(String)).returns(T::Boolean) }
  def poll_secret_matches?(candidate)
    return false if candidate.blank?

    ActiveSupport::SecurityUtils.secure_compare(self.class.digest_poll_secret(candidate), poll_secret_digest)
  end

  # Checks a typed pairing code under a row lock. A wrong code counts a
  # failure; reaching MAX_PAIRING_ATTEMPTS expires the signup.
  sig { params(candidate: T.nilable(String)).returns(T::Boolean) }
  def verify_pairing_code!(candidate)
    with_lock do
      next false if expired?

      typed = candidate.to_s.gsub(/[\s-]/, "")
      next true if typed.present? && ActiveSupport::SecurityUtils.secure_compare(pairing_code_digest_for(typed), pairing_code_digest)

      attempts = failed_pairing_attempts + 1
      attrs = { failed_pairing_attempts: attempts }
      attrs[:expires_at] = Time.current if attempts >= MAX_PAIRING_ATTEMPTS
      update!(attrs)
      false
    end
  end

  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def claimable_by?(user)
    return false if user.nil? || principal_user_id.nil?

    pending? && !expired? && principal_user_id == user.id
  end

  sig { params(ai_agent: User).void }
  def claim!(ai_agent:)
    with_lock do
      raise NotClaimable, "signup is #{expired? ? "expired" : state}" unless pending? && !expired?
      raise NotClaimable, "agent's principal is not the named principal" unless ai_agent.parent_id == principal_user_id

      update!(
        state: "claimed",
        ai_agent_user: ai_agent,
        claimed_at: Time.current,
        expires_at: PICKUP_LIFETIME.from_now
      )
    end
  end

  sig { void }
  def decline!
    with_lock do
      raise NotClaimable, "signup is #{expired? ? "expired" : state}" unless pending? && !expired?

      update!(state: "declined")
    end
  end

  # Mints the agent's MCP token and returns its plaintext, once. Returns nil
  # when there is nothing to hand over: not claimed yet, the agent is not
  # active, the pickup window lapsed, or the token was already collected.
  # Minting here rather than at the claim means the plaintext is never stored.
  sig { returns(T.nilable(String)) }
  def pick_up!
    with_lock do
      next nil unless agent_ready_for_pickup?

      token = T.must(ai_agent_user).api_tokens.new(
        tenant: tenant,
        name: "Agent signup connection",
        scopes: ApiToken.read_scopes + ApiToken.write_scopes,
        expires_at: 1.year.from_now,
        token_type: "mcp"
      )
      token.save!
      update!(state: "redeemed", api_token: token, redeemed_at: Time.current)
      token.plaintext_token
    end
  end

  # What the agent is told when polling. An unmatched signup reads as
  # `pending` until it expires, exactly like a matched one nobody has
  # claimed yet.
  sig { returns(String) }
  def agent_status
    return state if ["redeemed", "declined"].include?(state)
    return "expired" if expired?
    return "pending" if pending?

    agent_ready_for_pickup? ? "ready" : "claimed_awaiting_billing"
  end

  sig { returns(T::Boolean) }
  def agent_ready_for_pickup?
    agent = ai_agent_user
    return false if agent.nil? || !claimed? || expired?
    return false if agent.pending_billing_setup? || agent.suspended?

    # Archived state lives on the agent's membership of this signup's tenant.
    membership = T.must(tenant).tenant_users.find_by(user: agent)
    !membership.nil? && !membership.archived?
  end

  sig { params(secret: String).returns(String) }
  def self.digest_poll_secret(secret)
    Digest::SHA256.hexdigest(secret)
  end

  private

  # A six-digit code has too little entropy for a bare hash to protect it at
  # rest, so it is keyed with an app secret and bound to this signup.
  sig { params(code: String).returns(String) }
  def pairing_code_digest_for(code)
    key = Rails.application.key_generator.generate_key("agent_signup_pairing_code")
    OpenSSL::HMAC.hexdigest("SHA256", key, "#{public_id}:#{code}")
  end

  sig { void }
  def assign_credentials
    self.public_id = SecureRandom.urlsafe_base64(24) if self[:public_id].nil?
    return if poll_secret_digest.present?

    self.poll_secret = SecureRandom.urlsafe_base64(32)
    self.poll_secret_digest = self.class.digest_poll_secret(T.must(poll_secret))
    self.pairing_code = SecureRandom.random_number(10**PAIRING_CODE_DIGITS).to_s.rjust(PAIRING_CODE_DIGITS, "0")
    self.pairing_code_digest = pairing_code_digest_for(T.must(pairing_code))
  end

  sig { void }
  def assign_expires_at
    self.expires_at = PENDING_LIFETIME.from_now if self[:expires_at].nil?
  end
end
