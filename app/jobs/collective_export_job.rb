# typed: true
# frozen_string_literal: true

class CollectiveExportJob < TenantScopedJob
  extend T::Sig

  queue_as :low_priority

  sig { params(data_export_id: String).void }
  def perform(data_export_id)
    data_export = DataExport.unscoped_for_system_job.find_by(id: data_export_id)
    return unless data_export
    return unless data_export.status == "pending"

    set_tenant_context!(data_export.tenant)
    CollectiveExportService.new(data_export: data_export).perform!
    DataExportMailer.export_ready(data_export: data_export).deliver_later
  end
end
