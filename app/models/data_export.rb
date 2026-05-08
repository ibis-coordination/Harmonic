# typed: true

class DataExport < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :collective
  belongs_to :user

  has_one_attached :file, dependent: :destroy

  STATUSES = ["pending", "processing", "completed", "failed"].freeze

  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: ["pending", "processing"]) }
  scope :completed, -> { where(status: "completed") }
  scope :expired, -> { where(expires_at: ...Time.current) }

  sig { returns(T::Boolean) }
  def expired?
    expires_at.present? && T.must(expires_at) < Time.current
  end

  sig { returns(T::Boolean) }
  def downloadable?
    status == "completed" && !expired? && file.attached?
  end
end
