# typed: true
# frozen_string_literal: true

class ReindexSearchJob < TenantScopedJob
  extend T::Sig

  queue_as :low_priority

  # Reindex a single item within its tenant context
  sig { params(item_type: String, item_id: String, tenant_id: String).void }
  def perform(item_type:, item_id:, tenant_id:)
    tenant = Tenant.find_by(id: tenant_id)
    return unless tenant

    set_tenant_context!(tenant)

    # Now queries will be properly scoped
    item = item_type.constantize.find_by(id: item_id)
    return unless item

    SearchIndexer.reindex(item)
  end
end
