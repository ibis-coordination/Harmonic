# typed: true

class AutomationRule < ApplicationRecord
  extend T::Sig
  include HasTruncatedId
  include MightNotBelongToCollective
  include HasDeletedAt

  TRIGGER_TYPES = ["event", "schedule", "webhook", "manual"].freeze

  belongs_to :tenant
  belongs_to :collective, optional: true
  belongs_to :user, optional: true
  belongs_to :ai_agent, class_name: "User", optional: true
  belongs_to :created_by, class_name: "User"
  belongs_to :updated_by, class_name: "User", optional: true
  has_many :automation_rule_runs, dependent: :destroy

  validates :name, presence: true
  validates :trigger_type, presence: true, inclusion: { in: TRIGGER_TYPES }
  validate :only_one_scope_type
  validate :ai_agent_must_be_agent_type
  validate :webhook_path_required_for_webhook_trigger
  validate :require_task_for_internal_agent_rule
  validate :no_webhook_shape_on_collective_only_rule
  validate :one_notification_webhook_per_user

  before_validation :generate_webhook_secret, on: :create
  before_validation :generate_webhook_path, on: :create

  # "Delete" on a rule soft-deletes it (HasDeletedAt#soft_delete!) so run
  # history, task-run attribution, and bridge-setup references survive.
  # Hard destroy cascades through automation_rule_runs (dependent:
  # :destroy) and is reserved for data-retention tooling via
  # `allow_hard_destroy`.
  before_destroy :block_unsanctioned_hard_destroy, prepend: true
  attr_accessor :allow_hard_destroy

  # A soft-deleted rule must never fire regardless of its enabled flag —
  # every dispatch path composes from this scope.
  scope :enabled, -> { where(enabled: true, deleted_at: nil) }
  # Matches both the singular `event_type` (legacy) and `event_types` array forms.
  # Uses jsonb's `@>` containment operator (no `?` to escape) — array form must
  # be a JSON array of strings; the bind is a one-element JSON array literal.
  scope :for_event_type, lambda { |event_type|
    where(trigger_type: "event").where(
      "trigger_config->>'event_type' = :t OR trigger_config->'event_types' @> :arr::jsonb",
      t: event_type,
      arr: [event_type].to_json
    )
  }
  scope :for_ai_agent, ->(ai_agent) { where(ai_agent_id: ai_agent.id) }
  scope :scheduled, -> { where(trigger_type: "schedule") }
  # Excludes notification-webhook rules (managed in their own UI) from
  # general automation listings.
  scope :excluding_notification_webhooks, lambda {
    where("(actions->>'webhook_url') IS NULL OR (ai_agent_id IS NULL AND user_id IS NULL)")
  }
  # The recipient's notification webhook rule, if any. Recipient is a User
  # (human) or an AI agent (also a User). Backed by the partial unique index
  # on (tenant_id, COALESCE(ai_agent_id, user_id)) — at most one row.
  scope :notification_webhook_for, lambda { |owner|
    column = owner.ai_agent? ? :ai_agent_id : :user_id
    not_deleted
      .where(trigger_type: "event")
      .where(column => owner.id)
      .where("(actions->>'webhook_url') IS NOT NULL")
  }

  sig { returns(T::Boolean) }
  def agent_rule?
    ai_agent_id.present?
  end

  sig { returns(T::Boolean) }
  def internal_agent_rule?
    ai_agent_id.present? && !!ai_agent&.internal_ai_agent?
  end

  sig { returns(T::Boolean) }
  def notification_webhook_rule?
    return false if ai_agent_id.nil? && user_id.nil?

    actions.is_a?(Hash) && actions["webhook_url"].present?
  end

  sig { returns(T::Boolean) }
  def collective_rule?
    collective_id.present? && ai_agent_id.nil?
  end

  sig { returns(T::Boolean) }
  def user_rule?
    user_id.present? && ai_agent_id.nil? && collective_id.nil?
  end

  sig { returns(T::Boolean) }
  def manual_trigger?
    trigger_type == "manual"
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def manual_inputs
    trigger_config&.dig("inputs") || {}
  end

  sig { returns(T.nilable(String)) }
  def event_type
    trigger_config&.dig("event_type")
  end

  # All event types this rule matches, normalized across the singular
  # `event_type` and array `event_types` trigger_config forms.
  sig { returns(T::Array[String]) }
  def event_types
    Array(trigger_config&.dig("event_types") || trigger_config&.dig("event_type"))
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

  sig { returns(T::Array[String]) }
  def allowed_ips
    trigger_config&.dig("allowed_ips") || []
  end

  sig { returns(T::Boolean) }
  def ip_restricted?
    allowed_ips.any?
  end

  sig { params(ip_address: String).returns(T::Boolean) }
  def ip_allowed?(ip_address)
    return true unless ip_restricted?

    begin
      client_ip = IPAddr.new(ip_address)
      allowed_ips.any? do |allowed|
        allowed_range = IPAddr.new(allowed)
        allowed_range.include?(client_ip)
      rescue IPAddr::InvalidAddressError
        false
      end
    rescue IPAddr::InvalidAddressError
      false
    end
  end

  sig { returns(T.nilable(String)) }
  def timezone
    trigger_config&.dig("timezone") || "UTC"
  end

  sig { returns(T.nilable(Time)) }
  def next_scheduled_run
    return nil unless trigger_type == "schedule" && enabled?

    cron = cron_expression
    return nil if cron.blank?

    tz = timezone || "UTC"
    begin
      fugit_cron = Fugit::Cron.parse("#{cron} #{tz}")
      return nil unless fugit_cron

      fugit_cron.next_time.to_t
    rescue StandardError
      nil
    end
  end

  sig { returns(String) }
  def path
    if ai_agent_id.present?
      agent_tu = TenantUser.find_by(tenant_id: tenant_id, user_id: ai_agent_id)
      "/ai-agents/#{agent_tu&.handle}/automations/#{truncated_id}"
    elsif collective_id.present?
      c = Collective.tenant_scoped_only(tenant_id).find_by(id: collective_id)
      "#{c&.path}/settings/automations/#{truncated_id}"
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
    scopes_set = [ai_agent_id, collective_id, user_id].compact.count
    return unless scopes_set > 1

    # Agent rules can have ai_agent_id set alongside others being nil
    # Collective rules have collective_id set
    # User rules have user_id set
    if ai_agent_id.present? && (collective_id.present? || user_id.present?)
      errors.add(:base, "Agent rules cannot have collective or user scope set")
    elsif collective_id.present? && user_id.present?
      errors.add(:base, "Rule cannot be both collective-level and user-level")
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
  def require_task_for_internal_agent_rule
    return unless internal_agent_rule?

    task = actions.is_a?(Hash) ? actions["task"] : nil
    errors.add(:actions, "must include a task") if task.blank?
  end

  sig { void }
  def no_webhook_shape_on_collective_only_rule
    return unless collective_id.present? && ai_agent_id.nil? && user_id.nil?
    return unless actions.is_a?(Hash) && actions["webhook_url"].present?

    errors.add(:actions, "collective-only rules cannot use notification-webhook shape")
  end

  sig { void }
  def one_notification_webhook_per_user
    return unless notification_webhook_rule?

    recipient_id = ai_agent_id || user_id
    return if recipient_id.nil?

    scope = AutomationRule.tenant_scoped_only(tenant_id).not_deleted.where(
      "(ai_agent_id = :rid OR user_id = :rid) AND (actions->>'webhook_url') IS NOT NULL",
      rid: recipient_id
    )
    scope = scope.where.not(id: id) if persisted?
    return unless scope.exists?

    errors.add(:base, "This user already has a notification webhook. Edit or delete the existing one first.")
  end

  sig { void }
  def block_unsanctioned_hard_destroy
    return if allow_hard_destroy

    errors.add(:base, "Automation rules are soft-deleted (soft_delete!), not destroyed — destroying would cascade into run history.")
    throw :abort
  end

  # Soft-deleting a rule also disables it and records who did it. The
  # rule stops dispatching, disappears from listings, and stops counting
  # for uniqueness and billing, while its row — and every run, task run,
  # and bridge-setup row referencing it — survives.
  sig { params(by: T.nilable(User)).returns(T::Hash[Symbol, T.untyped]) }
  def soft_delete_updates(by)
    { enabled: false, updated_by: by }
  end

  sig { void }
  def generate_webhook_secret
    # Always generate a secret - used for both incoming webhook verification
    # and signing outgoing webhook actions
    self.webhook_secret = SecureRandom.hex(32) if webhook_secret.blank?
  end

  sig { void }
  def generate_webhook_path
    return unless trigger_type == "webhook" && webhook_path.blank?

    self.webhook_path = SecureRandom.alphanumeric(16).downcase
  end
end
