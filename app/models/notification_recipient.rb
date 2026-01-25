# typed: true

class NotificationRecipient < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :notification
  belongs_to :user

  validates :channel, presence: true, inclusion: { in: ["in_app", "email"] }
  validates :status, presence: true, inclusion: { in: ["pending", "delivered", "read", "dismissed", "rate_limited"] }

  scope :unread, -> { where(read_at: nil, dismissed_at: nil) }
  scope :in_app, -> { where(channel: "in_app") }
  scope :email, -> { where(channel: "email") }
  scope :pending, -> { where(status: "pending") }
  scope :delivered, -> { where(status: "delivered") }

  # Scheduled reminder scopes
  scope :scheduled, -> { where.not(scheduled_for: nil).where("scheduled_for > ?", Time.current) }
  scope :due, -> { where.not(scheduled_for: nil).where("scheduled_for <= ?", Time.current) }
  scope :immediate, -> { where(scheduled_for: nil) }
  # All notifications that are not scheduled for the future (immediate + due reminders)
  scope :not_scheduled, -> { where(scheduled_for: nil).or(where("scheduled_for <= ?", Time.current)) }

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

  sig { returns(T::Boolean) }
  def scheduled?
    scheduled_for.present? && scheduled_for > Time.current
  end

  sig { returns(T::Boolean) }
  def due?
    scheduled_for.present? && scheduled_for <= Time.current
  end
end
