# typed: true

class WebhookDelivery < ApplicationRecord
  extend T::Sig

  STATUSES = %w[pending success failed retrying].freeze

  belongs_to :webhook
  belongs_to :event

  validates :status, presence: true, inclusion: { in: STATUSES }

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
