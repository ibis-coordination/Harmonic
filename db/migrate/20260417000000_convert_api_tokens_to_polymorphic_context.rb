# typed: true
# frozen_string_literal: true

class ConvertApiTokensToPolymorphicContext < ActiveRecord::Migration[7.2]
  def up
    # Add polymorphic columns
    add_column :api_tokens, :context_type, :string, null: true
    add_column :api_tokens, :context_id, :uuid, null: true

    # Migrate existing data
    execute <<-SQL
      UPDATE api_tokens
      SET context_type = 'AiAgentTaskRun', context_id = ai_agent_task_run_id
      WHERE ai_agent_task_run_id IS NOT NULL
    SQL

    # Remove old column and its foreign key
    remove_foreign_key :api_tokens, :ai_agent_task_runs, column: :ai_agent_task_run_id
    remove_index :api_tokens, :ai_agent_task_run_id
    remove_column :api_tokens, :ai_agent_task_run_id

    # Add index on polymorphic association
    add_index :api_tokens, [:context_type, :context_id]
  end

  def down
    add_column :api_tokens, :ai_agent_task_run_id, :uuid, null: true

    execute <<-SQL
      UPDATE api_tokens
      SET ai_agent_task_run_id = context_id
      WHERE context_type = 'AiAgentTaskRun'
    SQL

    add_index :api_tokens, :ai_agent_task_run_id
    add_foreign_key :api_tokens, :ai_agent_task_runs, column: :ai_agent_task_run_id

    remove_index :api_tokens, [:context_type, :context_id]
    remove_column :api_tokens, :context_type
    remove_column :api_tokens, :context_id
  end
end
