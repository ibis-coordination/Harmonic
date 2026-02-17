class AddAutomationRuleToAiAgentTaskRuns < ActiveRecord::Migration[7.0]
  def change
    # Optional reference - task runs can be triggered manually or by automations
    add_reference :ai_agent_task_runs, :automation_rule, null: true, foreign_key: true, type: :uuid
  end
end
