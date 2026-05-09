# typed: true
# frozen_string_literal: true

class CollectiveImportJob < TenantScopedJob
  extend T::Sig

  queue_as :low_priority

  sig { params(data_import_id: String).void }
  def perform(data_import_id)
    data_import = DataImport.unscoped_for_system_job.find_by(id: data_import_id)
    return unless data_import
    return unless data_import.status == "pending"

    set_tenant_context!(data_import.tenant)
    CollectiveImportService.new(data_import: data_import).perform!
    data_import.file.purge if data_import.file.attached?
  end
end
