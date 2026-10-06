# typed: true

# An external agent's request to join a tenant, naming the email of the human
# who will be their principal. The agent starts the signup unauthenticated;
# whoever proves control of that email claims it while logged in, joining
# and activating first if they have to; the agent then collects an MCP
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
# Only digests of the last two are stored. The named email is stored as a
# keyed digest too: it identifies the addressee without keeping an address
# an anonymous caller typed.
#
# Lifecycle:
#   * `AgentSignup.start!` — creates a `pending` signup. Whether the addressee
#     is emailed is a separate decision (`claim_email_deliverable?`); the row
#     and the agent-facing responses are the same either way.
#   * `#claim!` — the addressee accepted and the agent was created; records
#     them as `principal_user`. Restarts the expiry clock for the pickup.
#   * `#decline!` — the addressee refused; recorded the same way.
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
  belongs_to :invite, optional: true

  # Plaintext credentials, available only on the instance `start!` returns.
  attr_accessor :poll_secret, :pairing_code

  validates :public_id, presence: true, uniqueness: { scope: :tenant_id }
  validates :poll_secret_digest, :pairing_code_digest, :principal_email_digest, :expires_at, presence: true
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
      handle: T.nilable(String),
      invite: T.nilable(Invite)
    ).returns(AgentSignup)
  end
  def self.start!(tenant:, principal_email:, name:, handle: nil, invite: nil)
    digest = principal_email_digest_for(principal_email)

    transaction do
      signup = create!(
        tenant: tenant,
        principal_email_digest: digest,
        invite: invite,
        proposed_name: name.to_s.strip,
        proposed_handle: handle.to_s.strip.presence
      )
      expire_pending_beyond_cap!(tenant: tenant, principal_email_digest: digest)
      signup
    end
  end

  # Deterministic, so a signup can be looked up by the email it names; keyed,
  # so the column is not a rainbow table of every address agents have typed.
  sig { params(email: T.nilable(String)).returns(String) }
  def self.principal_email_digest_for(email)
    key = Rails.application.key_generator.generate_key("agent_signup_principal_email")
    OpenSSL::HMAC.hexdigest("SHA256", key, email.to_s.strip.downcase)
  end

  # Whether the claim email goes to this address: whether its holder could
  # claim after at most registering, verifying, and joining. A member can
  # (today's rule, on any tenant). A non-member can when the tenant is open
  # to anyone who logs in, or when the signup carries an invite a member
  # issued. An account that cannot act (suspended, deleting, non-human) or an
  # address two accounts share gets nothing. A signup is never an invite: on
  # an invite-only tenant, no invite means no email.
  sig { params(tenant: Tenant, email: T.nilable(String), invite: T.nilable(Invite)).returns(T::Boolean) }
  def self.claim_email_deliverable?(tenant:, email:, invite:)
    normalized = email.to_s.strip.downcase
    return false if normalized.blank?

    candidates = User.where("LOWER(email) = ?", normalized).limit(2).to_a
    return false if candidates.size > 1

    user = candidates.first
    if user
      return false unless user.human? && !user.suspended? && user.deletion_requested_at.nil?
      return true if tenant.tenant_users.exists?(user: user)
    end

    !tenant.require_invite? || !invite.nil?
  end

  # An invite a signup may carry: live, on this tenant, for an invitable
  # collective, and shareable. A user-specific invite names its holder and is
  # accepted by logging in, not by a link an agent passes along.
  sig { params(tenant: Tenant, code: T.nilable(String)).returns(T.nilable(Invite)) }
  def self.usable_invite(tenant:, code:)
    normalized = code.to_s.strip
    return nil if normalized.blank?

    invite = Invite.tenant_scoped_only(tenant.id).find_by(code: normalized)
    return nil if invite.nil? || invite.expired? || !invite.collective_invitable? || invite.invited_user_id.present?

    invite
  end

  # Whether this user may act as human principal on this tenant right now:
  # a human, a member, with a verified email, not suspended, not on the way
  # out. The claim page routes a non-member or unverified addressee through
  # joining and activation first; this is the check once they are back.
  sig { params(user: User, tenant: Tenant).returns(T::Boolean) }
  def self.eligible_principal?(user, tenant:)
    user.human? &&
      user.email_verified? &&
      !user.suspended? &&
      user.deletion_requested_at.nil? &&
      tenant.tenant_users.exists?(user: user)
  end

  # Open signups addressed to this user's email on this tenant.
  sig { params(tenant: Tenant, user: User).returns(ActiveRecord::Relation) }
  def self.open_pending_addressed_to(tenant:, user:)
    tenant_scoped_only(tenant.id).open_pending.where(principal_email_digest: principal_email_digest_for(user.email))
  end

  sig { params(tenant: Tenant, principal_email_digest: String).void }
  def self.expire_pending_beyond_cap!(tenant:, principal_email_digest:)
    surplus_ids = tenant_scoped_only(tenant.id)
      .open_pending
      .where(principal_email_digest: principal_email_digest)
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

  # The signup's own page, where the agent calls check_agent_signup.
  sig { returns(String) }
  def path
    "/agent-signups/#{public_id}"
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

  # The addressee: a human who has proved control of the named email. The
  # verified email is the proof, whatever the tenant requires of its members.
  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def addressed_to?(user)
    return false if user.nil? || !user.human? || !user.email_verified?

    ActiveSupport::SecurityUtils.secure_compare(self.class.principal_email_digest_for(user.email), principal_email_digest)
  end

  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def claimable_by?(user)
    pending? && !expired? && addressed_to?(user)
  end

  sig { params(ai_agent: User).void }
  def claim!(ai_agent:)
    with_lock do
      raise NotClaimable, "signup is #{expired? ? "expired" : state}" unless pending? && !expired?

      principal = ai_agent.parent
      raise NotClaimable, "agent's principal is not the addressee" unless addressed_to?(principal)

      update!(
        state: "claimed",
        principal_user: principal,
        ai_agent_user: ai_agent,
        claimed_at: Time.current,
        expires_at: PICKUP_LIFETIME.from_now
      )
    end
  end

  sig { params(by: User).void }
  def decline!(by:)
    with_lock do
      raise NotClaimable, "signup is #{expired? ? "expired" : state}" unless pending? && !expired?

      update!(state: "declined", principal_user: by)
    end
  end

  # Mints the agent's MCP token and returns its plaintext, once. Returns nil
  # when there is nothing to hand over: not claimed yet, the agent is not
  # active, the pickup window lapsed, or the token was already collected.
  # Minting here rather than at the claim means the plaintext is never stored.
  sig { returns(T.nilable(String)) }
  def pick_up!
    # Agents poll this every few seconds. Skip the row lock until there is
    # something to hand over, so a poll never queues behind a claim in flight.
    return nil unless claimed?

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
    # A claimed signup whose pickup lapsed is not "expired": the agent exists,
    # and starting a new signup would create a second one.
    return claimed? ? "pickup_window_closed" : "expired" if expired?
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
