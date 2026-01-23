# typed: true

class Webhook < ApplicationRecord
  extend T::Sig
  include HasTruncatedId

  belongs_to :tenant
  belongs_to :superagent, optional: true
  belongs_to :user, optional: true
  belongs_to :created_by, class_name: "User"
  has_many :webhook_deliveries, dependent: :destroy

  scope :for_user, ->(user) { where(user_id: user.id) }

  validates :name, presence: true
  validates :url, presence: true
  validate :url_must_use_https_in_production
  validate :user_or_superagent_not_both

  sig { void }
  def url_must_use_https_in_production
    return if Rails.env.development? || Rails.env.test?
    return if url.blank?
    errors.add(:url, "must use HTTPS") unless url.start_with?("https://")
  end
  validates :secret, presence: true
  validates :events, presence: true

  before_validation :generate_secret, on: :create
  before_validation :skip_superagent_for_user_webhooks

  scope :enabled, -> { where(enabled: true) }

  sig { params(event_type: String).returns(T::Boolean) }
  def subscribed_to?(event_type)
    return false if events.blank?
    events.include?(event_type) || events.include?("*")
  end

  sig { returns(String) }
  def path
    if user_id.present?
      # Find the user's handle through tenant_users for this webhook's tenant
      tu = TenantUser.find_by(tenant_id: tenant_id, user_id: user_id)
      "/u/#{tu&.handle}/webhooks"
    else
      s = Superagent.unscoped.find_by(id: superagent_id)
      "/studios/#{s&.handle}/settings/webhooks/#{truncated_id}"
    end
  end

  private

  sig { void }
  def generate_secret
    self.secret = SecureRandom.hex(32) if secret.blank?
  end

  # User-level webhooks should not have superagent_id set automatically
  sig { void }
  def skip_superagent_for_user_webhooks
    self.superagent_id = nil if user_id.present?
  end

  sig { void }
  def user_or_superagent_not_both
    if user_id.present? && superagent_id.present?
      errors.add(:base, "Webhook cannot be both user-level and studio-level")
    end
  end
end
