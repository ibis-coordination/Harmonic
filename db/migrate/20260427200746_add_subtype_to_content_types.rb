class AddSubtypeToContentTypes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :subtype, :string, null: false, default: "text"
    add_column :decisions, :subtype, :string, null: false, default: "vote"
    add_column :commitments, :subtype, :string, null: false, default: "action"
  end
end
