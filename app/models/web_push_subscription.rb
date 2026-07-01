# typed: true

# A WebPushSubscription is a browser push endpoint a user registered from one
# of their devices. Subscriptions are user-global (no tenant_id — like
# RefreshToken, a device belongs to the user, not to a tenant); whether a
# given tenant's notifications are pushed is the per-tenant `web_push`
# channel preference on TenantUser.
#
# Rows are revoked rather than deleted (keeps delivery-failure forensics):
# `gone` when the push service returns 404/410 for the endpoint, `user`/
# `admin` for explicit revocation. Re-subscribing on the same endpoint
# un-revokes the row.
#
# Only human users get push subscriptions. AI agents receive
# `notifications.delivered` / `reminders.delivered` webhooks; collective
# identities don't have personal devices.
class WebPushSubscription < ApplicationRecord
  extend T::Sig

  VALID_REVOKE_REASONS = ["gone", "user", "admin"].freeze

  belongs_to :user

  scope :active, -> { where(revoked_at: nil) }

  validates :endpoint, presence: true, uniqueness: { scope: :user_id }
  validates :p256dh_key, presence: true
  validates :auth_key, presence: true
  validates :revoked_reason, inclusion: { in: VALID_REVOKE_REASONS, allow_nil: true }
  validate :user_must_be_human, on: :create

  # Create or refresh the subscription row for (user, endpoint). Browsers
  # occasionally rotate keys on an existing endpoint, and a re-subscribe on a
  # previously revoked endpoint means the device is live again.
  sig do
    params(
      user: User,
      endpoint: String,
      p256dh_key: String,
      auth_key: String,
      request: T.untyped
    ).returns(WebPushSubscription)
  end
  def self.upsert_for!(user:, endpoint:, p256dh_key:, auth_key:, request: nil)
    subscription = find_or_initialize_by(user: user, endpoint: endpoint)
    subscription.assign_attributes(
      p256dh_key: p256dh_key,
      auth_key: auth_key,
      last_seen_at: Time.current,
      revoked_at: nil,
      revoked_reason: nil
    )
    if request
      subscription.user_agent = request.user_agent&.first(255)
      subscription.device_label = DeviceLabel.parse(request.user_agent)
    end
    subscription.save!
    subscription
  end

  sig { returns(T::Boolean) }
  def active?
    revoked_at.nil?
  end

  sig { params(reason: String).void }
  def revoke!(reason:)
    raise ArgumentError, "invalid reason" unless VALID_REVOKE_REASONS.include?(reason)
    return unless active?

    update!(revoked_at: Time.current, revoked_reason: reason)
  end

  # Stamp a non-fatal delivery error (anything other than a gone endpoint).
  # The subscription stays active; the fields exist for forensics and for
  # spotting endpoints that consistently fail.
  sig { params(message: String).void }
  def record_error!(message)
    update!(last_error: message.first(255), last_error_at: Time.current)
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
