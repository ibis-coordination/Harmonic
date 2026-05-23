# typed: true

# An image embedded in a Note as first-class content. Parallel to Attachment
# but image-only: stricter content-type allowlist, image variants
# (thumbnail/medium/large), alt text, captions, and display ordering for
# in-note galleries. MediaItem is always available regardless of the
# `file_attachments` feature flag — image-in-note is a core content
# capability, not an optional file-upload feature.
class MediaItem < ApplicationRecord
  extend T::Sig
  include HasMagicByteValidation

  # Per-file byte cap. Generous enough for normal phone photos and
  # screenshots, low enough that a flood of huge uploads can't push a
  # collective past its storage quota in one shot. Note: source images
  # also need to fit in libvips memory during variant generation, so this
  # is a hard upper bound regardless of collective quota.
  MAX_FILE_BYTES = 15.megabytes

  # Bound user-supplied metadata so a single MediaItem can't carry an
  # unbounded text payload (storage DoS) and so we can render in compact
  # contexts (feed strip, alt attribute) without truncation surprises.
  MAX_ALT_TEXT_LENGTH = 500
  MAX_CAPTION_LENGTH = 5_000

  ALLOWED_CONTENT_TYPES = %w[
    image/png
    image/jpeg
    image/gif
    image/webp
  ].freeze

  KNOWN_VARIANTS = %i[thumbnail medium large].freeze

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :collective
  before_validation :set_collective_id
  belongs_to :mediable, polymorphic: true
  belongs_to :created_by, class_name: "User"
  belongs_to :updated_by, class_name: "User"

  has_one_attached :file, dependent: :destroy do |attachable|
    attachable.variant :thumbnail,
                       resize_to_fill: [250, 250],
                       format: :webp,
                       saver: { quality: 80 },
                       preprocessed: true
    attachable.variant :medium,
                       resize_to_limit: [800, 800],
                       format: :webp,
                       saver: { quality: 82 },
                       preprocessed: true
    attachable.variant :large,
                       resize_to_limit: [1600, 1600],
                       format: :webp,
                       saver: { quality: 85 },
                       preprocessed: true
  end

  validates :file, presence: true
  validates :alt_text, length: { maximum: MAX_ALT_TEXT_LENGTH }, allow_blank: true
  validates :caption, length: { maximum: MAX_CAPTION_LENGTH }, allow_blank: true
  validate :validate_file_type_and_size

  before_save :set_file_metadata

  scope :ordered, -> { order(:display_order, :created_at) }

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(tenant_id.presence || Tenant.current_id)
  end

  sig { void }
  def set_collective_id
    self.collective_id = T.must(collective_id.presence || Collective.current_id)
  end

  sig { void }
  def set_file_metadata
    blob = T.unsafe(file).blob
    self.content_type = blob.content_type
    self.byte_size = blob.byte_size
  end

  sig { void }
  def validate_file_type_and_size
    return unless file.attached?

    blob = T.unsafe(file).blob
    unless ALLOWED_CONTENT_TYPES.include?(blob.content_type)
      errors.add(:file, "type #{blob.content_type} is not an allowed image type (allowed: #{ALLOWED_CONTENT_TYPES.join(', ')})")
    end

    if blob.byte_size > MAX_FILE_BYTES
      mb = (MAX_FILE_BYTES / 1.megabyte.to_f).round(1)
      errors.add(:file, "size must be less than #{mb} MB")
    end
  end

  # URL for a specific variant; nil if no file attached.
  # Raises ArgumentError for unrecognized variants so a typo at a call site
  # fails fast rather than producing a broken-image URL silently.
  sig { params(variant: T.nilable(Symbol)).returns(T.nilable(String)) }
  def url(variant: nil)
    return nil unless file.attached?

    if variant.nil?
      Rails.application.routes.url_helpers.rails_blob_url(file, only_path: true)
    else
      raise ArgumentError, "unknown image variant: #{variant.inspect}" unless KNOWN_VARIANTS.include?(variant)

      Rails.application.routes.url_helpers.rails_representation_url(
        file.variant(variant),
        only_path: true
      )
    end
  end

  sig { returns(T.nilable(String)) }
  def alt_text_for_display
    alt_text.presence
  end

  # Returns alt_text escaped for safe inclusion inside the brackets of a
  # markdown image link: `![<alt>](<url>)`. Markdown delimiters that would
  # break out of the alt-text slot — `]`, `(`, `)`, `\` — are
  # backslash-escaped, and newlines are collapsed to spaces so the image
  # syntax stays single-line. Without this, a user-controlled alt could
  # inject an arbitrary markdown link/image into the `.md` view that AI
  # agents consume.
  sig { returns(String) }
  def alt_text_for_markdown
    escape_markdown_inline(alt_text.to_s)
  end

  sig { returns(String) }
  def caption_for_markdown
    escape_markdown_inline(caption.to_s)
  end

  private

  sig { params(text: String).returns(String) }
  def escape_markdown_inline(text)
    text.gsub(/[\\\[\]()*_`<>]/) { |c| "\\#{c}" }
        .gsub(/\r?\n/, " ")
  end
end
