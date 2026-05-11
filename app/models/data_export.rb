# typed: true

class DataExport < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :collective
  belongs_to :user

  has_one_attached :file, dependent: :destroy

  STATUSES = ["pending", "processing", "completed", "failed"].freeze
  EXPORT_TYPES = ["collective", "user"].freeze

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :export_type, presence: true, inclusion: { in: EXPORT_TYPES }

  scope :active, -> { where(status: ["pending", "processing"]) }
  scope :completed, -> { where(status: "completed") }
  scope :expired, -> { where(expires_at: ...Time.current) }
  scope :collective_exports, -> { where(export_type: "collective") }
  scope :user_exports, -> { where(export_type: "user") }

  sig { returns(T::Boolean) }
  def expired?
    expires_at.present? && T.must(expires_at) < Time.current
  end

  sig { returns(T::Boolean) }
  def downloadable?
    status == "completed" && !expired? && file.attached?
  end
end
