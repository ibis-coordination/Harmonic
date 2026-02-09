# typed: false

class ReindexSearchJob < ApplicationJob
  queue_as :low_priority

  # Reindex a single item
  def perform(item_type:, item_id:, tenant_id:)
    item = item_type.constantize.tenant_scoped_only(tenant_id).find_by(id: item_id)
    return unless item

    SearchIndexer.reindex(item)
  end
end
