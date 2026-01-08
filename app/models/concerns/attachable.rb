# typed: false

module Attachable
  extend ActiveSupport::Concern

  def attach!(files)
    return if files.nil?
    if files.respond_to?(:each)
      files.each do |file|
        next unless file.respond_to?(:content_type)
        Attachment.create!(
          tenant_id: self.tenant_id,
          studio_id: self.studio_id,
          attachable: self,
          file: file,
          created_by: self.created_by,
          updated_by: self.updated_by,
        )
      end
    else
      Attachment.create!(
        tenant_id: self.tenant_id,
        studio_id: self.studio_id,
        attachable: self,
        file: files,
        created_by: self.created_by,
        updated_by: self.updated_by,
      )
    end
  end

  included do
    # has_many_attached :files, dependent: :destroy
    has_many :attachments, as: :attachable, dependent: :destroy
  end
end
