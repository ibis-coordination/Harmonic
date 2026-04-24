class BackfillAgentSessionSteps < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    AiAgentTaskRun.unscoped_for_system_job.where.not(steps_data: nil).find_each do |task_run|
      steps_data = task_run.steps_data
      next unless steps_data.is_a?(Array) && steps_data.any?

      # Skip if rows already exist (idempotent)
      next if AgentSessionStep.where(ai_agent_task_run_id: task_run.id).exists?

      steps_data.each_with_index do |step, i|
        step = step.is_a?(Hash) ? step : step.to_h
        timestamp = step["timestamp"].present? ? Time.parse(step["timestamp"]) : task_run.created_at

        AgentSessionStep.create!(
          ai_agent_task_run_id: task_run.id,
          position: i,
          step_type: step["type"],
          detail: step["detail"] || {},
          created_at: timestamp,
        )
      rescue StandardError => e
        Rails.logger.warn("BackfillAgentSessionSteps: skipping step #{i} for task_run #{task_run.id}: #{e.message}")
      end
    end
  end

  def down
    AgentSessionStep.delete_all
  end
end
