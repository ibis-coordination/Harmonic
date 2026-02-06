# frozen_string_literal: true

class AddAgentConfigurationToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :agent_configuration, :jsonb, default: {}
  end
end
