# typed: false

# require 'clamav'
class Attachment < ApplicationRecord
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :attachable, polymorphic: true
  belongs_to :created_by, class_name: 'User'
  belongs_to :updated_by, class_name: 'User'

  has_one_attached :file, dependent: :destroy
  before_save :set_file_metadata
  validates :file, presence: true
  validates :created_by, presence: true
  validates :updated_by, presence: true
  validate :validate_file

  def set_tenant_id
    self.tenant_id ||= Tenant.current_id
  end

  def set_studio_id
    self.studio_id ||= Studio.current_id
  end

  def set_file_metadata
    self.name = file.blob.filename
    self.content_type = file.blob.content_type
    self.byte_size = file.blob.byte_size
    # self.url = Rails.application.routes.url_helpers.rails_blob_path(file, only_path: true)
  end

  def validate_file
    is_image = file.blob.content_type.start_with?('image/')
    is_text = file.blob.content_type.start_with?('text/')
    is_pdf = file.blob.content_type == 'application/pdf'
    unless is_image || is_text || is_pdf
      errors.add(:files, "must be an acceptable file type (image, text, pdf)")
    end

    if file.blob.byte_size > 10.megabytes
      errors.add(:files, 'size must be less than 10MB')
    end
    scan_for_viruses
  end

  def scan_for_viruses
    # unless ClamAV.instance.scanfile(file.download)
    #   errors.add(:file, 'contains a virus')
    # end
  end

  def path
    "#{attachable.path}/attachments/#{id}"
  end

  def blob_path
    Rails.application.routes.url_helpers.rails_blob_path(file, only_path: true)
  end

  def filename
    name
  end
end