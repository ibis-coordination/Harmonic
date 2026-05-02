# typed: true

class AgentSessionStep < ApplicationRecord
  extend T::Sig

  STEP_TYPES = [
    "navigate", "think", "execute", "done", "error", "security_warning", "scratchpad_update", "scratchpad_update_failed",
  ].freeze

  belongs_to :tenant
  belongs_to :ai_agent_task_run
  belongs_to :sender, class_name: "User", optional: true

  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :step_type, presence: true, inclusion: { in: STEP_TYPES }

  scope :chronological, -> { order(:position) }

  sig { returns(T::Hash[String, T.untyped]) }
  def to_step_hash
    hash = {
      "type" => step_type,
      "detail" => detail || {},
      "timestamp" => created_at.iso8601,
    }
    hash["sender_id"] = sender_id if sender_id.present?
    hash
  end
end
