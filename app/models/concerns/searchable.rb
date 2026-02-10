# typed: false

module Searchable
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_search_reindex, on: [:create, :update]
    after_commit :delete_from_search_index, on: :destroy
  end

  private

  def enqueue_search_reindex
    ReindexSearchJob.perform_later(
      item_type: self.class.name,
      item_id: id,
      tenant_id: tenant_id
    )
  end

  def delete_from_search_index
    # Delete synchronously since the record is being destroyed
    SearchIndexer.delete(self)
  end
end
