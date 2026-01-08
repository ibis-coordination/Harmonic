# typed: true

# require 'clamav'
class Attachment < ApplicationRecord
  extend T::Sig

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

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(tenant_id.presence || Tenant.current_id)
  end

  sig { void }
  def set_studio_id
    self.studio_id = T.must(studio_id.presence || Studio.current_id)
  end

  sig { void }
  def set_file_metadata
    blob = T.unsafe(file).blob
    self.name = blob.filename
    self.content_type = blob.content_type
    self.byte_size = blob.byte_size
    # self.url = Rails.application.routes.url_helpers.rails_blob_path(file, only_path: true)
  end

  sig { void }
  def validate_file
    blob = T.unsafe(file).blob
    is_image = blob.content_type.start_with?('image/')
    is_text = blob.content_type.start_with?('text/')
    is_pdf = blob.content_type == 'application/pdf'
    unless is_image || is_text || is_pdf
      errors.add(:files, "must be an acceptable file type (image, text, pdf)")
    end

    if blob.byte_size > 10.megabytes
      errors.add(:files, 'size must be less than 10MB')
    end
    scan_for_viruses
  end

  sig { void }
  def scan_for_viruses
    # unless ClamAV.instance.scanfile(file.download)
    #   errors.add(:file, 'contains a virus')
    # end
  end

  sig { returns(String) }
  def path
    "#{T.unsafe(attachable).path}/attachments/#{id}"
  end

  sig { returns(String) }
  def blob_path
    Rails.application.routes.url_helpers.rails_blob_path(file, only_path: true)
  end

  sig { returns(T.nilable(String)) }
  def filename
    name
  end
end