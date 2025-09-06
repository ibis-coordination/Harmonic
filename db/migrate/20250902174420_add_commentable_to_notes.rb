class AddCommentableToNotes < ActiveRecord::Migration[7.0]
  def change
    add_column :notes, :commentable_type, :string
    add_column :notes, :commentable_id, :uuid

    add_index :notes, [:commentable_type, :commentable_id], name: 'index_notes_on_commentable'
  end
end
