# typed: false

module Searchable
  extend ActiveSupport::Concern

  included do
    after_commit :index_for_search, on: :create
    after_commit :enqueue_search_reindex, on: :update
    after_commit :delete_from_search_index, on: :destroy
  end

  private

  # New content indexes synchronously so it is immediately visible on
  # search-backed feeds (read-your-writes). The engagement counts the
  # indexer computes are empty or near-empty at create, so the count
  # queries are cheap and this costs about one upsert. Updates stay
  # async: they fire from hot interactive paths (votes, comments, links
  # all reindex their parent) where eventual count consistency is
  # invisible.
  def index_for_search
    return if Current.importing_data
    return if respond_to?(:deleted?) && deleted?

    SearchIndexer.reindex(self)
  rescue StandardError => e
    # Never block content creation on the index; fall back to the async job.
    Rails.logger.error("Synchronous search indexing failed for #{self.class.name} #{id}: #{e.message}")
    enqueue_search_reindex
  end

  def enqueue_search_reindex
    return if Current.importing_data
    return if respond_to?(:deleted?) && deleted?

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
