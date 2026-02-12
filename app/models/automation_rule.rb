# typed: true

class AutomationRule < ApplicationRecord
  extend T::Sig
  include HasTruncatedId
  include MightNotBelongToSuperagent

  TRIGGER_TYPES = ["event", "schedule", "webhook"].freeze

  belongs_to :tenant
  belongs_to :superagent, optional: true
  belongs_to :user, optional: true
  belongs_to :ai_agent, class_name: "User", optional: true
  belongs_to :created_by, class_name: "User"
  has_many :automation_rule_runs, dependent: :destroy

  validates :name, presence: true
  validates :trigger_type, presence: true, inclusion: { in: TRIGGER_TYPES }
  validate :only_one_scope_type
  validate :ai_agent_must_be_agent_type
  validate :webhook_path_required_for_webhook_trigger

  before_validation :generate_webhook_secret, on: :create
  before_validation :generate_webhook_path, on: :create

  scope :enabled, -> { where(enabled: true) }
  scope :for_event_type, ->(event_type) { where(trigger_type: "event").where("trigger_config->>'event_type' = ?", event_type) }
  scope :for_ai_agent, ->(ai_agent) { where(ai_agent_id: ai_agent.id) }
  scope :scheduled, -> { where(trigger_type: "schedule") }

  sig { returns(T::Boolean) }
  def agent_rule?
    ai_agent_id.present?
  end

  sig { returns(T::Boolean) }
  def studio_rule?
    superagent_id.present? && ai_agent_id.nil?
  end

  sig { returns(T::Boolean) }
  def user_rule?
    user_id.present? && ai_agent_id.nil? && superagent_id.nil?
  end

  sig { returns(T.nilable(String)) }
  def event_type
    trigger_config&.dig("event_type")
  end

  sig { returns(T.nilable(String)) }
  def mention_filter
    trigger_config&.dig("mention_filter")
  end

  sig { returns(T.nilable(String)) }
  def task_template
    # For agent rules, task is stored in actions as a string
    return nil unless agent_rule?

    actions.is_a?(String) ? actions : actions&.dig("task")
  end

  sig { returns(T.nilable(Integer)) }
  def max_steps
    trigger_config&.dig("max_steps")&.to_i
  end

  sig { returns(T.nilable(String)) }
  def cron_expression
    trigger_config&.dig("cron")
  end

  sig { returns(T.nilable(String)) }
  def timezone
    trigger_config&.dig("timezone") || "UTC"
  end

  sig { returns(String) }
  def path
    if ai_agent_id.present?
      agent_tu = TenantUser.find_by(tenant_id: tenant_id, user_id: ai_agent_id)
      "/ai-agents/#{agent_tu&.handle}/automations/#{truncated_id}"
    elsif superagent_id.present?
      s = Superagent.tenant_scoped_only(tenant_id).find_by(id: superagent_id)
      "/studios/#{s&.handle}/settings/automations/#{truncated_id}"
    else
      tu = TenantUser.find_by(tenant_id: tenant_id, user_id: user_id)
      "/u/#{tu&.handle}/settings/automations/#{truncated_id}"
    end
  end

  sig { void }
  def increment_execution_count!
    update!(execution_count: execution_count + 1, last_executed_at: Time.current)
  end

  private

  sig { void }
  def only_one_scope_type
    scopes_set = [ai_agent_id, superagent_id, user_id].compact.count
    return unless scopes_set > 1

    # Agent rules can have ai_agent_id set alongside others being nil
    # Studio rules have superagent_id set
    # User rules have user_id set
    if ai_agent_id.present? && (superagent_id.present? || user_id.present?)
      errors.add(:base, "Agent rules cannot have superagent or user scope set")
    elsif superagent_id.present? && user_id.present?
      errors.add(:base, "Rule cannot be both studio-level and user-level")
    end
  end

  sig { void }
  def ai_agent_must_be_agent_type
    return if ai_agent_id.blank?

    agent = User.find_by(id: ai_agent_id)
    return if agent&.ai_agent?

    errors.add(:ai_agent, "must be an AI agent")
  end

  sig { void }
  def webhook_path_required_for_webhook_trigger
    return unless trigger_type == "webhook"

    return if webhook_path.present?

    errors.add(:webhook_path, "is required for webhook triggers")
  end

  sig { void }
  def generate_webhook_secret
    self.webhook_secret = SecureRandom.hex(32) if webhook_secret.blank? && trigger_type == "webhook"
  end

  sig { void }
  def generate_webhook_path
    return unless trigger_type == "webhook" && webhook_path.blank?

    self.webhook_path = SecureRandom.alphanumeric(16).downcase
  end
end
