# typed: false

# Shared magic-byte validation for ActiveStorage attachments. Both Attachment
# (multi-category) and MediaItem (image-only) use this to catch
# content-type spoofing — a file claiming to be image/png whose first bytes
# are HTML or shellcode is rejected before any downstream processing
# (vips, virus scan, etc.) ever sees it.
#
# The host model must declare its ActiveStorage attachment name via
# `magic_byte_attachment :file` (defaults to `:file`). The blob's
# content_type is the authoritative claim — that's what ActiveStorage uses
# everywhere downstream, and it's populated as soon as the blob is attached
# (unlike a denormalized content_type column which is set in before_save).
module HasMagicByteValidation
  extend ActiveSupport::Concern

  # Each content type maps to a list of signatures. A signature is either a
  # raw byte prefix (matched at offset 0) or a Proc taking the read bytes
  # and returning a Boolean. Procs are needed for formats where checking a
  # single prefix is insufficient — e.g., WebP starts with "RIFF" like
  # many other RIFF-container formats (WAV, AVI), so the byte 8-11 "WEBP"
  # tag is what actually identifies the format.
  MAGIC_BYTES = {
    "image/png" => ["\x89PNG\r\n\x1a\n".b],
    "image/jpeg" => ["\xFF\xD8\xFF".b],
    "image/gif" => ["GIF87a".b, "GIF89a".b],
    "image/webp" => [
      ->(bytes) { bytes.byteslice(0, 4) == "RIFF".b && bytes.byteslice(8, 4) == "WEBP".b },
    ],
    "image/bmp" => ["BM".b],
    "application/pdf" => ["%PDF".b],
  }.freeze

  # Bytes to fetch from the blob for any signature check. Generous enough to
  # cover RIFF-container offset checks; cheap to read.
  MAGIC_BYTE_READ_LENGTH = 16

  included do
    validate :validate_magic_bytes
  end

  # Validate that the attached blob's actual leading bytes match the
  # content type claimed by the blob. Text files have no reliable magic
  # bytes and are skipped; unknown types are also skipped — callers should
  # reject those at the content-type whitelist level.
  def validate_magic_bytes
    attachment_name = self.class.magic_byte_attachment_name
    attachment = public_send(attachment_name)
    return unless attachment.attached?

    blob = attachment.blob
    content_type = blob.content_type.to_s

    return if content_type.start_with?("text/")

    signatures = MAGIC_BYTES[content_type]
    return unless signatures

    begin
      file_bytes = blob.download_chunk(0...MAGIC_BYTE_READ_LENGTH)
    rescue StandardError
      # If we can't read the file, leave it to other validations / blob
      # integrity checks. We don't want to mask a missing-blob error as a
      # magic-bytes error.
      return
    end

    matches = signatures.any? do |sig|
      sig.respond_to?(:call) ? sig.call(file_bytes) : file_bytes.start_with?(sig)
    end
    return if matches

    errors.add(attachment_name, "content does not match claimed type #{content_type}")
  end

  class_methods do
    # Name of the ActiveStorage attachment to inspect. Default is :file.
    def magic_byte_attachment(name)
      @magic_byte_attachment_name = name.to_sym
    end

    def magic_byte_attachment_name
      @magic_byte_attachment_name || :file
    end
  end
end
