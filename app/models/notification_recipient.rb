# typed: true

class NotificationRecipient < ApplicationRecord
  extend T::Sig

  belongs_to :notification
  belongs_to :user

  validates :channel, presence: true, inclusion: { in: ["in_app", "email"] }
  validates :status, presence: true, inclusion: { in: ["pending", "delivered", "read", "dismissed"] }

  scope :unread, -> { where(read_at: nil, dismissed_at: nil) }
  scope :in_app, -> { where(channel: "in_app") }
  scope :email, -> { where(channel: "email") }
  scope :pending, -> { where(status: "pending") }
  scope :delivered, -> { where(status: "delivered") }

  sig { void }
  def read!
    update!(read_at: Time.current, status: "read")
  end

  sig { void }
  def dismiss!
    update!(dismissed_at: Time.current, status: "dismissed")
  end

  sig { void }
  def mark_delivered!
    update!(delivered_at: Time.current, status: "delivered")
  end

  sig { returns(T::Boolean) }
  def read?
    T.unsafe(self).read_at.present?
  end

  sig { returns(T::Boolean) }
  def dismissed?
    T.unsafe(self).dismissed_at.present?
  end
end
