# typed: true
# frozen_string_literal: true

class UserDataExportJob < TenantScopedJob
  extend T::Sig

  queue_as :low_priority

  sig { params(data_export_id: String).void }
  def perform(data_export_id)
    data_export = DataExport.unscoped_for_system_job.find_by(id: data_export_id)
    return unless data_export
    return unless data_export.status == "pending"
    return unless data_export.export_type == "user"

    set_tenant_context!(data_export.tenant)
    UserDataExportService.new(data_export: data_export).perform!
    DataExportMailer.user_export_ready(data_export: data_export).deliver_later
  end
end
