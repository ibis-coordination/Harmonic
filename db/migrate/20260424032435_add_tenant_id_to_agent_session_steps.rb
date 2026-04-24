class AddTenantIdToAgentSessionSteps < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    add_reference :agent_session_steps, :tenant, type: :uuid, null: true, foreign_key: true, index: false

    # Backfill tenant_id from the associated task run
    execute <<~SQL
      UPDATE agent_session_steps
      SET tenant_id = ai_agent_task_runs.tenant_id
      FROM ai_agent_task_runs
      WHERE agent_session_steps.ai_agent_task_run_id = ai_agent_task_runs.id
    SQL

    change_column_null :agent_session_steps, :tenant_id, false
  end

  def down
    remove_reference :agent_session_steps, :tenant
  end
end
