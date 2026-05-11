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
    # Defense-in-depth: the controller's require_human_user gates this at
    # the entry point, but if a DataExport row ever gets created another
    # way (DB-level access, future code path, bug) we bail here so the
    # service's ArgumentError doesn't end up logged with sensitive context.
    return unless data_export.user&.user_type == "human"

    set_tenant_context!(data_export.tenant)
    UserDataExportService.new(data_export: data_export).perform!
    DataExportMailer.user_export_ready(data_export: data_export).deliver_later
  end
end
