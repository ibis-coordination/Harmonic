# typed: true

class Notification < ApplicationRecord
  extend T::Sig

  NOTIFICATION_TYPES = %w[mention comment participation system reminder].freeze

  belongs_to :tenant
  belongs_to :event, optional: true

  has_many :notification_recipients, dependent: :destroy
  has_many :recipients, through: :notification_recipients, source: :user

  validates :notification_type, presence: true, inclusion: { in: NOTIFICATION_TYPES }
  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :of_type, ->(type) { where(notification_type: type) }

  sig { returns(String) }
  def notification_category
    T.must(T.unsafe(self).notification_type)
  end
end
