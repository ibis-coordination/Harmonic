class RemoveNameFromCommitmentParticipants < ActiveRecord::Migration[7.0]
  def change
    remove_column :commitment_participants, :name, :string
  end
end
