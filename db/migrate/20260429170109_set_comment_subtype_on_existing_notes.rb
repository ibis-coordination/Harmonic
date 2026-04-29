class SetCommentSubtypeOnExistingNotes < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE notes
      SET subtype = 'comment'
      WHERE commentable_type IS NOT NULL
        AND commentable_id IS NOT NULL
        AND subtype != 'comment'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE notes
      SET subtype = 'text'
      WHERE commentable_type IS NOT NULL
        AND commentable_id IS NOT NULL
        AND subtype = 'comment'
    SQL
  end
end
