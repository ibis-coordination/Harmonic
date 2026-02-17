# typed: true

class WebhookDelivery < ApplicationRecord
  extend T::Sig

  STATUSES = %w[pending success failed retrying].freeze

  belongs_to :tenant
  belongs_to :event, optional: true
  belongs_to :automation_rule_run

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :url, presence: true
  validates :secret, presence: true

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
