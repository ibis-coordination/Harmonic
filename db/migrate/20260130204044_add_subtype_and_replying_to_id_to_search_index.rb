# typed: false

class AddSubtypeAndReplyingToIdToSearchIndex < ActiveRecord::Migration[7.0]
  def change
    add_column :search_index, :subtype, :string
    add_column :search_index, :replying_to_id, :uuid

    # Index for filtering by subtype (e.g., excluding comments)
    add_index :search_index, [:tenant_id, :superagent_id, :subtype], name: "idx_search_index_subtype"

    # Index for replying-to filter
    add_index :search_index, [:tenant_id, :replying_to_id], name: "idx_search_index_replying_to"
  end
end
