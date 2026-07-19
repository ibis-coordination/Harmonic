# estimated_cost_usd has had no writer since the agent-runner migration
# (73d92de5, 2026-04-16) deleted the old Sidekiq execution stack that
# computed it — every run since carries nil, and the aggregates built on it
# summed to silent zeros. Per-run cost now reads live from the gateway usage
# ledger (LLMUsageRecord.ai_agent_task_run_id), the single source of truth.
class DropEstimatedCostUsdFromAiAgentTaskRuns < ActiveRecord::Migration[7.2]
  def change
    remove_column :ai_agent_task_runs, :estimated_cost_usd, :numeric, precision: 10, scale: 6
  end
end
