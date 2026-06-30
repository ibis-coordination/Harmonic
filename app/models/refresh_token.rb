# typed: true

# A RefreshToken represents a trusted device for silent re-auth. After a user
# logs in interactively (OAuth + 2FA when required), a refresh token is issued
# and stored in a parent-domain httpOnly cookie. When the session cookie's
# timestamps go stale and the controller-side timeout enforcement clears the
# session, the silent-refresh `before_action` consumes this token to mint a new
# session without bouncing through the auth subdomain.
#
# Rotation: every successful use rotates the token (sets `rotated_at`, mints a
# successor in the same `family_id`). Presenting an already-rotated token
# within `REPLAY_GRACE_WINDOW` is benign (multi-tab race); outside it is a
# replay attack → the entire family is revoked.
#
# Only human users get refresh tokens. AI agents authenticate via API tokens /
# MCP; collective identities don't have personal logins.
class RefreshToken < ApplicationRecord
  extend T::Sig

  # Token lifetime before forced re-auth.
  LIFETIME = 90.days

  # Window during which presenting an already-rotated token is treated as a
  # benign in-flight race (e.g. two tabs refreshing concurrently).
  REPLAY_GRACE_WINDOW = 30.seconds

  # How recently the user must have passed 2FA on this device for silent
  # refresh to skip the 2FA re-prompt.
  TWO_FACTOR_TRUST_WINDOW = 30.days

  VALID_REVOKE_REASONS = [
    "user_logout",
    "rotation_replay",
    "user_ineligible",
    "admin",
    "password_change",
    "two_factor_disabled",
  ].freeze

  class AlreadyRotated < StandardError; end
  class NotRotatable < StandardError; end

  belongs_to :user

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  # Plaintext is only available immediately after issuance; never stored.
  attr_accessor :plaintext_token

  # Defense-in-depth: clear in-memory plaintext on reload so a caller holding
  # a reference after a DB refresh can't keep using a stale secret.
  def reload(*args)
    self.plaintext_token = nil
    super
  end

  validates :token_digest, presence: true, uniqueness: true
  validates :family_id, presence: true
  validates :expires_at, presence: true
  validates :last_used_at, presence: true
  validates :revoked_reason, inclusion: { in: VALID_REVOKE_REASONS, allow_nil: true }
  validate :user_must_be_human, on: :create

  sig { params(raw: String).returns(String) }
  def self.digest(raw)
    Digest::SHA256.hexdigest(raw)
  end

  # Issue a brand-new refresh token (new family). Used at successful interactive
  # login. The returned instance has `plaintext_token` populated for cookie
  # write; that value is never recoverable from the database afterward.
  sig do
    params(
      user: User,
      two_factor_at: T.nilable(ActiveSupport::TimeWithZone),
      request: T.untyped
    ).returns(RefreshToken)
  end
  def self.issue!(user:, two_factor_at: nil, request: nil)
    build_token!(
      user: user,
      family_id: SecureRandom.uuid,
      two_factor_at: two_factor_at,
      device_label: parse_device_label(request&.user_agent),
      user_agent: request&.user_agent.to_s.first(255),
      ip_at_issue: request&.remote_ip
    )
  end

  sig { params(raw: T.nilable(String)).returns(T.nilable(RefreshToken)) }
  def self.find_by_plaintext(raw)
    return nil if raw.blank?

    find_by(token_digest: digest(T.must(raw)))
  end

  # Revoke every non-revoked token in the family. Used on replay-detected
  # compromise.
  sig { params(family_id: String, reason: String).void }
  def self.revoke_family!(family_id, reason:)
    raise ArgumentError, "invalid reason" unless VALID_REVOKE_REASONS.include?(reason)

    where(family_id: family_id, revoked_at: nil)
      .update_all(revoked_at: Time.current, revoked_reason: reason)
  end

  # Revoke every non-revoked token for the user. Used on security-posture
  # changes that should kill device trust everywhere: password change, 2FA
  # disable, admin "log this user out everywhere".
  sig { params(user_id: String, reason: String).void }
  def self.revoke_all_for_user!(user_id, reason:)
    raise ArgumentError, "invalid reason" unless VALID_REVOKE_REASONS.include?(reason)

    where(user_id: user_id, revoked_at: nil)
      .update_all(revoked_at: Time.current, revoked_reason: reason)
  end

  sig { returns(T::Boolean) }
  def expired?
    expires_at < Time.current
  end

  sig { returns(T::Boolean) }
  def revoked?
    !revoked_at.nil?
  end

  sig { returns(T::Boolean) }
  def rotated?
    !rotated_at.nil?
  end

  sig { returns(T::Boolean) }
  def active?
    !revoked? && !expired?
  end

  # Rotate this token: mark self rotated, mint a successor in the same family,
  # return the successor with plaintext for the cookie write.
  sig { params(request: T.untyped).returns(RefreshToken) }
  def rotate!(request: nil)
    raise AlreadyRotated, "token already rotated" if rotated?
    raise NotRotatable, "token revoked or expired" unless active?

    successor = T.let(nil, T.nilable(RefreshToken))
    transaction do
      update!(rotated_at: Time.current, last_used_at: Time.current)
      successor = self.class.send(
        :build_token!,
        user: T.must(user),
        family_id: T.must(family_id),
        two_factor_at: two_factor_at,
        device_label: device_label,
        user_agent: request&.user_agent.to_s.first(255) || user_agent,
        ip_at_issue: request&.remote_ip || ip_at_issue
      )
    end
    T.must(successor)
  end

  sig { params(reason: String).void }
  def revoke!(reason:)
    raise ArgumentError, "invalid reason" unless VALID_REVOKE_REASONS.include?(reason)
    return if revoked?

    update!(revoked_at: Time.current, revoked_reason: reason)
  end

  sig do
    params(
      user: User,
      family_id: String,
      two_factor_at: T.nilable(ActiveSupport::TimeWithZone),
      device_label: T.nilable(String),
      user_agent: T.nilable(String),
      ip_at_issue: T.nilable(String)
    ).returns(RefreshToken)
  end
  private_class_method def self.build_token!(user:, family_id:, two_factor_at:, device_label:, user_agent:, ip_at_issue:)
    raw = SecureRandom.urlsafe_base64(32) # ~256 bits
    token = create!(
      user: user,
      token_digest: digest(raw),
      family_id: family_id,
      expires_at: LIFETIME.from_now,
      last_used_at: Time.current,
      two_factor_at: two_factor_at,
      device_label: device_label,
      user_agent: user_agent,
      ip_at_issue: ip_at_issue
    )
    token.plaintext_token = raw
    token
  end

  sig { params(ua: T.nilable(String)).returns(String) }
  private_class_method def self.parse_device_label(ua)
    return "Unknown device" if ua.blank?

    parts = [parse_platform(ua), parse_browser(ua)].compact
    parts.empty? ? "Unknown device" : parts.join(" · ")
  end

  sig { params(ua: String).returns(T.nilable(String)) }
  private_class_method def self.parse_platform(ua)
    case ua
    when /iPhone/i then "iPhone"
    when /iPad/i then "iPad"
    when /Android/i then "Android"
    when /Macintosh|Mac OS X/i then "Mac"
    when /Windows/i then "Windows PC"
    when /Linux/i then "Linux"
    end
  end

  # Order matters: Edge UA contains "Chrome", Opera UA contains "Chrome",
  # Chrome UA contains "Safari" — narrowest matches first.
  sig { params(ua: String).returns(T.nilable(String)) }
  private_class_method def self.parse_browser(ua)
    case ua
    when /Edg\//i then "Edge"
    when /OPR\//i then "Opera"
    when /Firefox\//i then "Firefox"
    when /Chrome\//i then "Chrome"
    when /Safari\//i then "Safari"
    end
  end

  private

  sig { void }
  def user_must_be_human
    u = user
    return if u.nil?
    return if u.human?

    errors.add(:user, "must be a human user")
  end
end
