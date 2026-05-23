class RenameTextSubtypeToPost < ActiveRecord::Migration[7.2]
  def up
    execute(<<~SQL.squish)
      UPDATE notes SET subtype = 'post' WHERE subtype = 'text'
    SQL

    execute(<<~SQL.squish)
      UPDATE search_index
      SET subtype = 'post'
      WHERE item_type = 'Note' AND subtype = 'text'
    SQL

    change_column_default :notes, :subtype, from: "text", to: "post"
  end

  def down
    change_column_default :notes, :subtype, from: "post", to: "text"

    execute(<<~SQL.squish)
      UPDATE search_index
      SET subtype = 'text'
      WHERE item_type = 'Note' AND subtype = 'post'
    SQL

    execute(<<~SQL.squish)
      UPDATE notes SET subtype = 'text' WHERE subtype = 'post'
    SQL
  end
end
