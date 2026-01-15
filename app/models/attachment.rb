# typed: true

# require 'clamav'
class Attachment < ApplicationRecord
  extend T::Sig

  # Magic byte signatures for file type validation
  MAGIC_BYTES = {
    "image/png" => ["\x89PNG\r\n\x1a\n".b],
    "image/jpeg" => ["\xFF\xD8\xFF".b],
    "image/gif" => ["GIF87a".b, "GIF89a".b],
    "image/webp" => ["RIFF".b], # WebP starts with RIFF, followed by file size, then WEBP
    "image/bmp" => ["BM".b],
    "application/pdf" => ["%PDF".b],
  }.freeze

  # Maximum filename length after sanitization
  MAX_FILENAME_LENGTH = 255

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :attachable, polymorphic: true
  belongs_to :created_by, class_name: "User"
  belongs_to :updated_by, class_name: "User"

  has_one_attached :file, dependent: :destroy
  before_save :set_file_metadata
  validates :file, presence: true
  validate :validate_file
  validate :validate_magic_bytes

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(tenant_id.presence || Tenant.current_id)
  end

  sig { void }
  def set_superagent_id
    self.superagent_id = T.must(superagent_id.presence || Superagent.current_id)
  end

  sig { void }
  def set_file_metadata
    blob = T.unsafe(file).blob
    self.name = sanitize_filename(blob.filename.to_s)
    self.content_type = blob.content_type
    self.byte_size = blob.byte_size
    # self.url = Rails.application.routes.url_helpers.rails_blob_path(file, only_path: true)
  end

  # Sanitize filename to prevent path traversal and other attacks
  sig { params(filename: String).returns(String) }
  def sanitize_filename(filename)
    # Replace path separators with underscores
    sanitized = filename.gsub(%r{[\\/]}, "_")

    # Remove path traversal attempts (.. followed by underscore or at start/end)
    sanitized = sanitized.gsub("..", "")

    # Remove null bytes and control characters
    sanitized = sanitized.gsub(/[\x00-\x1f\x7f]/, "")

    # Remove leading/trailing dots, underscores, and spaces
    sanitized = sanitized.strip.gsub(/\A[._]+|[._]+\z/, "")

    # Collapse multiple underscores
    sanitized = sanitized.gsub(/_+/, "_")

    # Ensure we have a valid filename
    sanitized = "unnamed" if sanitized.blank?

    # Truncate to max length while preserving extension
    if sanitized.length > MAX_FILENAME_LENGTH
      ext = File.extname(sanitized)
      base = File.basename(sanitized, ext)
      max_base_length = MAX_FILENAME_LENGTH - ext.length
      truncated_base = base[0, max_base_length] || ""
      sanitized = truncated_base + ext
    end

    sanitized
  end

  sig { void }
  def validate_file
    blob = T.unsafe(file).blob
    is_image = blob.content_type.start_with?("image/")
    is_text = blob.content_type.start_with?("text/")
    is_pdf = blob.content_type == "application/pdf"
    errors.add(:files, "must be an acceptable file type (image, text, pdf)") unless is_image || is_text || is_pdf

    errors.add(:files, "size must be less than 10MB") if blob.byte_size > 10.megabytes
    scan_for_viruses
  end

  sig { void }
  def scan_for_viruses
    return unless file.attached?
    return unless virus_scanning_enabled?

    blob = T.unsafe(file).blob

    # Download file to a temp file for scanning
    Tempfile.create(["attachment_scan", File.extname(blob.filename.to_s)]) do |temp_file|
      temp_file.binmode
      temp_file.write(blob.download)
      temp_file.flush

      # Clamby.safe? returns true if file is clean, false if virus found
      errors.add(:file, "contains a virus or malicious content") unless Clamby.safe?(temp_file.path)
    end
  rescue StandardError => e
    # Log error but don't block upload if scanning fails
    # In production, you may want to fail-closed instead
    Rails.logger.error("Virus scanning failed: #{e.message}")
  end

  sig { returns(T::Boolean) }
  def virus_scanning_enabled?
    # Check if ClamAV is available by checking if clamdscan exists
    # and the clamav service is configured
    return false if Rails.env.test? # Skip in tests unless explicitly enabled

    @virus_scanning_enabled ||= T.let(
      system("which clamdscan > /dev/null 2>&1"),
      T.nilable(T::Boolean)
    )
    @virus_scanning_enabled || false
  end

  # Validate that file content matches claimed content type using magic bytes
  sig { void }
  def validate_magic_bytes
    return unless file.attached?

    blob = T.unsafe(file).blob
    content_type = blob.content_type

    # Only validate types we have signatures for
    # Text files don't have reliable magic bytes
    return if content_type.start_with?("text/")

    signatures = MAGIC_BYTES[content_type]
    return unless signatures # Unknown type, skip validation

    # Read enough bytes to check the signature
    max_sig_length = signatures.map(&:length).max
    begin
      file_bytes = blob.download_chunk(0...max_sig_length)
    rescue StandardError
      # If we can't read the file, let other validations handle it
      return
    end

    # Check if any signature matches
    matches = signatures.any? do |sig|
      file_bytes.start_with?(sig)
    end

    return if matches

    errors.add(:file, "content does not match claimed type #{content_type}")
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
