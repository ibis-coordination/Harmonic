class RenameSimulatedToSubagent < ActiveRecord::Migration[7.0]
  def up
    User.where(user_type: "simulated").update_all(user_type: "subagent")
  end

  def down
    User.where(user_type: "subagent").update_all(user_type: "simulated")
  end
end
