# typed: true

class StripeCustomer < ApplicationRecord
  extend T::Sig

  belongs_to :billable, polymorphic: true

  has_many :ai_agents, class_name: "User", foreign_key: "stripe_customer_id", dependent: :nullify
  has_many :task_runs, class_name: "AiAgentTaskRun", foreign_key: "stripe_customer_id", dependent: :nullify

  validates :stripe_id, presence: true, uniqueness: true
  validates :billable_id, uniqueness: { scope: :billable_type }
end
