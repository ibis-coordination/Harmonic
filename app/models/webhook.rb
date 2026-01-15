# typed: true

class Webhook < ApplicationRecord
  extend T::Sig
  include HasTruncatedId

  belongs_to :tenant
  belongs_to :superagent, optional: true
  belongs_to :created_by, class_name: "User"
  has_many :webhook_deliveries, dependent: :destroy

  validates :name, presence: true
  validates :url, presence: true, format: { with: /\Ahttps:\/\//, message: "must use HTTPS" }
  validates :secret, presence: true
  validates :events, presence: true

  before_validation :generate_secret, on: :create

  scope :enabled, -> { where(enabled: true) }

  sig { params(event_type: String).returns(T::Boolean) }
  def subscribed_to?(event_type)
    return false if events.blank?
    events.include?(event_type) || events.include?("*")
  end

  sig { returns(String) }
  def path
    s = Superagent.unscoped.find_by(id: superagent_id)
    "/studios/#{s&.handle}/settings/webhooks/#{truncated_id}"
  end

  private

  sig { void }
  def generate_secret
    self.secret = SecureRandom.hex(32) if secret.blank?
  end
end
