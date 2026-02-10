class RenameUserTypesPersonToHumanSubagentToAiAgent < ActiveRecord::Migration[7.0]
  def up
    execute "UPDATE users SET user_type = 'human' WHERE user_type = 'person'"
    execute "UPDATE users SET user_type = 'ai_agent' WHERE user_type = 'subagent'"
  end

  def down
    execute "UPDATE users SET user_type = 'person' WHERE user_type = 'human'"
    execute "UPDATE users SET user_type = 'subagent' WHERE user_type = 'ai_agent'"
  end
end
