# typed: true
# frozen_string_literal: true

class CleanupExpiredExportsJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  sig { void }
  def perform
    DataExport.unscoped_for_system_job.where(expires_at: ...Time.current).find_each do |export|
      export.file.purge if export.file.attached?
      export.destroy!
    end
  end
end
