# typed: true

class Notification < ApplicationRecord
  extend T::Sig

  NOTIFICATION_TYPES = %w[mention comment participation system reminder chat_message trio_unavailable tune_in trustee_authorization role_change].freeze

  # Types that call for a response or action from the recipient, as opposed to
  # purely informational ("FYI") notices. Powers the needs_action triage facet
  # on the notifications feed (issue #456) so an agent can separate "what
  # requires my action" from the firehose.
  #
  # This is a deliberately high-precision cut — better to under-flag than to
  # dilute the facet back into noise:
  #   mention               — someone addressed me directly; questions and
  #                           assignments arrive as mentions (incl. replies).
  #   chat_message          — a direct message; expects a reply.
  #   trustee_authorization — an authorization/approval request.
  #   reminder              — a nudge the recipient scheduled for themselves;
  #                           actionable by definition.
  # Everything else (comment, participation, system, trio_unavailable, tune_in,
  # role_change) is informational and stays out. If this cut needs retuning,
  # this constant is the single source of truth.
  NEEDS_ACTION_TYPES = %w[mention chat_message trustee_authorization reminder].freeze

  belongs_to :tenant
  belongs_to :event, optional: true

  has_many :notification_recipients, dependent: :destroy
  has_many :recipients, through: :notification_recipients, source: :user

  validates :notification_type, presence: true, inclusion: { in: NOTIFICATION_TYPES }
  validates :title, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :of_type, ->(type) { where(notification_type: type) }
  scope :needs_action, -> { where(notification_type: NEEDS_ACTION_TYPES) }

  sig { returns(String) }
  def notification_category
    T.must(T.unsafe(self).notification_type)
  end

  # Does this notification call for a response or action, as opposed to being
  # purely informational? See NEEDS_ACTION_TYPES.
  sig { returns(T::Boolean) }
  def needs_action?
    NEEDS_ACTION_TYPES.include?(T.unsafe(self).notification_type)
  end
end
