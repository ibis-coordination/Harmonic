# typed: false

# Include this concern in models that affect the search index of a parent item.
# When records are created, updated, or destroyed, the parent item's search index
# will be updated asynchronously.
#
# Models should define `search_index_items` to return the items that need reindexing.
#
# Example:
#   class NoteHistoryEvent < ApplicationRecord
#     include InvalidatesSearchIndex
#
#     def search_index_items
#       [note].compact
#     end
#   end
#
module InvalidatesSearchIndex
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_search_reindex_for_parent, on: [:create, :update, :destroy]
  end

  private

  def enqueue_search_reindex_for_parent
    items = search_index_items
    return if items.blank?

    items.each do |item|
      next if item.nil?

      ReindexSearchJob.perform_later(
        item_type: item.class.name,
        item_id: item.id,
        tenant_id: item.tenant_id
      )
    end
  end

  # Override this method in the including class to return the items that need reindexing.
  # Should return an array of items (Note, Decision, Commitment) or an empty array.
  def search_index_items
    []
  end
end
