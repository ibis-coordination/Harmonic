# typed: true

class DataImport < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :collective, optional: true
  belongs_to :user

  has_one_attached :file, dependent: :destroy

  STATUSES = ["pending", "validating", "importing", "completed", "failed"].freeze

  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: ["pending", "validating", "importing"]) }

  sig { returns(T::Boolean) }
  def in_progress?
    ["pending", "validating", "importing"].include?(status)
  end
end
