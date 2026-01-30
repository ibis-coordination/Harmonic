# typed: true

class AddReaderCountToSearchIndex < ActiveRecord::Migration[7.0]
  def change
    add_column :search_index, :reader_count, :integer, default: 0, null: false
  end
end
