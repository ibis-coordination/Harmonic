class AddLimitToCommitments < ActiveRecord::Migration[7.0]
  def change
    add_column :commitments, :limit, :integer
  end
end
