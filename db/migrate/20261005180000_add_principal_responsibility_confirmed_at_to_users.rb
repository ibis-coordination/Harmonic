# typed: true

class AddPrincipalResponsibilityConfirmedAtToUsers < ActiveRecord::Migration[7.2]
  def change
    # Set on an AI agent when its human principal confirmed, at creation or
    # claim, that they control the agent and take responsibility for what it
    # does. Nil on agents created before the confirmation existed.
    add_column :users, :principal_responsibility_confirmed_at, :datetime
  end
end
