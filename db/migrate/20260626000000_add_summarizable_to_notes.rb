class AddSummarizableToNotes < ActiveRecord::Migration[7.2]
  def change
    change_table :notes, bulk: true do |t|
      t.string :summarizable_type
      t.uuid :summarizable_id
    end
    add_index :notes, [:summarizable_type, :summarizable_id], unique: true
  end
end
