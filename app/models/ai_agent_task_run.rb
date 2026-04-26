# typed: true

class AiAgentTaskRun < ApplicationRecord
  extend T::Sig

  DEFAULT_MAX_STEPS = 30

  belongs_to :tenant
  belongs_to :ai_agent, class_name: "User"
  belongs_to :initiated_by, class_name: "User"
  belongs_to :automation_rule, optional: true
  belongs_to :chat_session, optional: true
  # Immutable billing attribution — stamped at run creation, never changed
  belongs_to :billing_customer, class_name: "StripeCustomer", foreign_key: "stripe_customer_id", optional: true

  has_many :agent_session_steps, -> { order(:position) }, dependent: :destroy
  has_many :ai_agent_task_run_resources, dependent: :destroy
  has_many :api_tokens, as: :context, dependent: :destroy

  validates :task, presence: true
  validates :max_steps, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 50 }
  validates :status, presence: true, inclusion: { in: ["queued", "pending", "running", "completed", "failed", "cancelled"] }
  validates :mode, presence: true, inclusion: { in: %w[task chat_turn] }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_ai_agent, ->(ai_agent) { where(ai_agent: ai_agent) }
  scope :completed, -> { where(status: "completed") }
  scope :with_usage, -> { where.not(total_tokens: 0) }
  scope :in_period, ->(start_date, end_date) { where(completed_at: start_date..end_date) }

  sig { params(start_date: T.any(Date, Time, ActiveSupport::TimeWithZone), end_date: T.any(Date, Time, ActiveSupport::TimeWithZone)).returns(T.any(Integer, Float, BigDecimal)) }
  def self.total_cost_for_period(start_date, end_date)
    completed.in_period(start_date, end_date).sum(:estimated_cost_usd)
  end

  # Thread-local context management for tracking which task run is currently executing
  class << self
    extend T::Sig

    sig { returns(T.nilable(String)) }
    def current_id
      Current.ai_agent_task_run_id
    end

    sig { params(id: T.nilable(String)).void }
    def current_id=(id)
      Current.ai_agent_task_run_id = id
    end

    sig { void }
    def clear_thread_scope
      Current.ai_agent_task_run_id = nil
    end

    sig do
      params(
        ai_agent: User,
        tenant: Tenant,
        initiated_by: User,
        task: String,
        max_steps: T.nilable(Integer),
        automation_rule: T.nilable(AutomationRule),
      ).returns(AiAgentTaskRun)
    end
    def create_queued(ai_agent:, tenant:, initiated_by:, task:, max_steps: nil, automation_rule: nil)
      model = ai_agent.agent_configuration&.dig("model") || "default"

      create!(
        tenant: tenant,
        ai_agent: ai_agent,
        initiated_by: initiated_by,
        task: task,
        max_steps: max_steps || DEFAULT_MAX_STEPS,
        model: model,
        status: "queued",
        automation_rule: automation_rule,
      )
    end
  end

  sig { returns(T.untyped) }
  def created_notes
    Note.where(id: ai_agent_task_run_resources.where(resource_type: "Note", action_type: "create").select(:resource_id))
  end

  sig { returns(T.untyped) }
  def created_decisions
    Decision.where(id: ai_agent_task_run_resources.where(resource_type: "Decision", action_type: "create").select(:resource_id))
  end

  sig { returns(T.untyped) }
  def created_commitments
    Commitment.where(id: ai_agent_task_run_resources.where(resource_type: "Commitment", action_type: "create").select(:resource_id))
  end

  sig { returns(T::Array[T.untyped]) }
  def all_resources
    ai_agent_task_run_resources.includes(:resource).map(&:resource)
  end

  sig { returns(T::Boolean) }
  def queued?
    status == "queued"
  end

  sig { returns(T::Boolean) }
  def running?
    status == "running"
  end

  sig { returns(T::Boolean) }
  def completed?
    status == "completed"
  end

  sig { returns(T::Boolean) }
  def failed?
    status == "failed"
  end

  sig { returns(T::Boolean) }
  def triggered_by_automation?
    automation_rule_id.present?
  end

  sig { void }
  def notify_parent_automation_runs!
    return unless triggered_by_automation?

    parent_runs = find_parent_automation_runs
    parent_runs.each do |run|
      next unless run.running?

      run.update_status_from_actions!
    rescue StandardError => e
      Rails.logger.error("AiAgentTaskRun: Failed to notify parent run #{run.id}: #{e.message}")
    end
  end

  sig { returns(T.nilable(String)) }
  def formatted_duration
    format_seconds(duration)
  end

  sig { returns(T.nilable(String)) }
  def formatted_cost
    return nil unless estimated_cost_usd&.positive?

    if T.must(estimated_cost_usd) < 0.01
      "< $0.01"
    else
      "$#{format("%.4f", estimated_cost_usd)}"
    end
  end

  sig { returns(T.nilable(String)) }
  def formatted_tokens
    return nil unless total_tokens&.positive?

    total_tokens.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  sig { params(max_length: Integer).returns(String) }
  def task_summary(max_length = 80)
    if task.length > max_length
      "#{task[0...max_length]}..."
    else
      task
    end
  end

  sig { returns(String) }
  def status_badge_class
    case status
    when "completed"
      success ? "pulse-badge-success" : "pulse-badge-danger"
    when "failed"
      "pulse-badge-danger"
    when "running"
      "pulse-badge-info"
    when "queued"
      "pulse-badge-warning"
    else # cancelled, pending, or unknown
      "pulse-badge-muted"
    end
  end

  sig { returns(T.nilable(String)) }
  def formatted_queue_wait
    format_seconds(queue_wait)
  end

  private

  sig { params(total: T.nilable(Numeric)).returns(T.nilable(String)) }
  def format_seconds(total)
    return nil unless total

    if total < 60
      "#{total.round(1)}s"
    elsif total < 3600
      minutes = (total / 60).floor
      seconds = (total % 60).round
      "#{minutes}m #{seconds}s"
    else
      hours = (total / 3600).floor
      minutes = ((total % 3600) / 60).floor
      "#{hours}h #{minutes}m"
    end
  end

  sig { returns(T::Array[AutomationRuleRun]) }
  def find_parent_automation_runs
    runs = []

    direct_run = AutomationRuleRun.find_by(ai_agent_task_run_id: id)
    runs << direct_run if direct_run

    AutomationRuleRun.where(status: "running").find_each do |run|
      actions = run.actions_executed || []
      has_this_task = actions.any? do |action|
        (action.dig("result", "task_run_id") == id) ||
          (action.dig("result", :task_run_id) == id)
      end
      runs << run if has_this_task
    end

    runs.uniq
  end

  sig { returns(T.nilable(Float)) }
  def duration
    return nil unless started_at && completed_at

    T.must(completed_at) - T.must(started_at)
  end

  sig { returns(T.nilable(Float)) }
  def queue_wait
    end_of_wait = started_at || completed_at
    return nil unless end_of_wait && created_at

    end_of_wait - created_at
  end
end
