class ChangeMaxStepsDefault < ActiveRecord::Migration[7.0]
  def change
    change_column_default :subagent_task_runs, :max_steps, from: 15, to: 30
  end
end
