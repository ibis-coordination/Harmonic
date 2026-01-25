# typed: true

class WebhookDelivery < ApplicationRecord
  extend T::Sig

  STATUSES = %w[pending success failed retrying].freeze

  belongs_to :tenant
  belongs_to :webhook
  belongs_to :event

  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :tenant_matches_webhook_tenant

  private

  sig { void }
  def tenant_matches_webhook_tenant
    return if webhook.blank? || tenant_id.blank?
    return if webhook.tenant_id == tenant_id

    errors.add(:tenant, "must match webhook tenant")
  end

  public

  scope :pending, -> { where(status: "pending") }
  scope :failed, -> { where(status: "failed") }
  scope :needs_retry, -> { where(status: "retrying").where("next_retry_at <= ?", Time.current) }

  sig { returns(T::Boolean) }
  def success?
    status == "success"
  end

  sig { returns(T::Boolean) }
  def failed?
    status == "failed"
  end

  sig { returns(T::Boolean) }
  def retrying?
    status == "retrying"
  end
end
