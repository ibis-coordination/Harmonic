# typed: false

require "open-uri"
require "image_processing/vips"
require "resolv"
require "ipaddr"
require "marcel"

module HasImage
  extend ActiveSupport::Concern

  # Greyscale-only default avatars, with white text. Brightness alone
  # distinguishes the three categories:
  #   humans      = light grey   (brightest)
  #   ai agents   = mid grey
  #   collectives = dark grey    (darkest)
  # All three pass WCAG AA against white text.
  HUMAN_AVATAR_COLOR = "#757575".freeze
  AI_AGENT_AVATAR_COLOR = "#555555".freeze
  COLLECTIVE_AVATAR_COLOR = "#333333".freeze

  # Source images get resized to fit within this box before being stored, so a
  # 50 MB phone photo doesn't sit around as an "original."
  SOURCE_MAX_DIMENSION = 1024

  # Cap raw byte size before handing input to vips. Protects against
  # decompression bombs and oversized uploads that would OOM the worker.
  MAX_SOURCE_BYTES = 20.megabytes

  # External fetch timeouts for image_url=. Set tight — this runs inside a
  # request thread today.
  FETCH_OPEN_TIMEOUT_SECONDS = 5
  FETCH_READ_TIMEOUT_SECONDS = 10

  KNOWN_VARIANTS = [:icon, :thumbnail, :display].freeze

  # Only formats vips reliably handles and that we want users to upload.
  ALLOWED_IMAGE_MIME_TYPES = [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/bmp",
  ].freeze

  def avatar_color
    COLLECTIVE_AVATAR_COLOR
  end

  def image_path(variant: nil)
    return nil unless image.attached?

    if variant.nil?
      Rails.application.routes.url_helpers.rails_blob_url(image, only_path: true)
    else
      raise ArgumentError, "unknown image variant: #{variant.inspect}" unless KNOWN_VARIANTS.include?(variant)

      Rails.application.routes.url_helpers.rails_representation_url(image.variant(variant), only_path: true)
    end
  end

  def image_url(variant: nil)
    image_path(variant: variant)
  end

  # Fetches an image from an external URL and attaches it. Validates the URL
  # to prevent SSRF (no loopback, private, or link-local addresses), bounds
  # the response size, applies a tight timeout, and verifies the actual bytes
  # are an allowed image type before storing.
  #
  # Silently no-ops on any validation failure; this is invoked from OAuth
  # signup paths where a malformed avatar URL shouldn't break account creation.
  def image_url=(url)
    if url.blank?
      image.purge
      return
    end

    safe_uri = parse_safe_external_uri(url)
    return unless safe_uri

    Tempfile.create(["downloaded_image"]) do |tempfile|
      tempfile.binmode
      next unless fetch_into!(safe_uri, tempfile)

      tempfile.rewind
      filename = File.basename(safe_uri.path).presence || "downloaded_image"
      attach_bounded_image!(tempfile, filename: filename)
    end
  rescue StandardError => e
    Rails.logger.warn("HasImage#image_url= failed: #{e.class}: #{e.message}")
    nil
  end

  def cropped_image_data=(cropped_image_data)
    if cropped_image_data.blank?
      image.purge
      return
    end

    payload = cropped_image_data.gsub(%r{^data:image/\w+;base64,}, "")
    # Rough encoded-size guard before we decode, so we don't allocate a
    # giant string from an attacker-controlled blob.
    raise ArgumentError, "image data too large" if payload.bytesize > (MAX_SOURCE_BYTES * 4 / 3) + 16

    image_data = Base64.decode64(payload)
    raise ArgumentError, "image data too large" if image_data.bytesize > MAX_SOURCE_BYTES

    Tempfile.create(["cropped_image", ".jpg"]) do |temp_file|
      temp_file.binmode
      temp_file.write(image_data)
      temp_file.rewind

      attach_bounded_image!(temp_file, filename: "profile_image.jpg")
      save!
    end
  end

  # Validates the actual file type via magic bytes, resizes to fit within
  # SOURCE_MAX_DIMENSION, and attaches. resize_to_limit is a no-op for images
  # already smaller than the limit, so this is safe for any allowed input.
  def attach_bounded_image!(io, filename:)
    io.rewind if io.respond_to?(:rewind)
    detected_type = Marcel::MimeType.for(io)
    io.rewind if io.respond_to?(:rewind)

    raise ArgumentError, "disallowed image type: #{detected_type.inspect}" unless ALLOWED_IMAGE_MIME_TYPES.include?(detected_type)

    processed = ImageProcessing::Vips
      .source(io)
      .resize_to_limit(SOURCE_MAX_DIMENSION, SOURCE_MAX_DIMENSION)
      .call

    # Upload synchronously: image.attach(io:) defers to after_commit, by
    # which point both `f` and `processed` are closed.
    File.open(processed.path) do |f|
      blob = ActiveStorage::Blob.create_and_upload!(io: f, filename: filename)
      image.attach(blob)
    end
  ensure
    processed&.close
    processed&.unlink if processed.respond_to?(:unlink)
  end

  # Returns a URI if the URL is HTTP(S), resolvable, and every IP it resolves
  # to is publicly routable. Returns nil for anything we'd refuse to fetch.
  def parse_safe_external_uri(url)
    uri = URI.parse(url)
    return nil unless ["http", "https"].include?(uri.scheme)
    return nil if uri.hostname.blank?

    addresses = Resolv.getaddresses(uri.hostname)
    return nil if addresses.empty?
    return nil unless addresses.all? { |addr| public_ip_address?(addr) }

    uri
  rescue URI::InvalidURIError, IPAddr::Error
    nil
  end

  # An address is "publicly routable" if it's not in any of the ranges we'd
  # consider an SSRF target. `#native` collapses IPv4-mapped IPv6
  # (`::ffff:127.0.0.1`) back to its IPv4 form so the loopback/private/
  # link-local checks apply uniformly.
  def public_ip_address?(addr)
    ip = IPAddr.new(addr).native
    return false if ip.loopback?       # 127/8, ::1
    return false if ip.private?        # RFC1918, fc00::/7
    return false if ip.link_local?     # 169.254/16, fe80::/10
    return false if ip.to_i.zero?      # 0.0.0.0, ::

    true
  rescue IPAddr::Error
    false
  end

  # Streams the response into the given tempfile, aborting if it would exceed
  # MAX_SOURCE_BYTES. Returns true on success, false on any failure.
  def fetch_into!(uri, tempfile)
    URI.parse(uri.to_s).open(
      "rb",
      open_timeout: FETCH_OPEN_TIMEOUT_SECONDS,
      read_timeout: FETCH_READ_TIMEOUT_SECONDS,
      content_length_proc: lambda { |size|
        raise IOError, "image too large (Content-Length #{size})" if size && size > MAX_SOURCE_BYTES
      },
      progress_proc: lambda { |size|
        raise IOError, "image too large (read #{size} bytes)" if size > MAX_SOURCE_BYTES
      }
    ) do |io|
      return false unless io.content_type.to_s.start_with?("image/")

      IO.copy_stream(io, tempfile)
    end
    true
  rescue StandardError => e
    Rails.logger.warn("HasImage#fetch_into! failed: #{e.class}: #{e.message}")
    false
  end

  included do
    has_one_attached :image, dependent: :destroy do |attachable|
      attachable.variant :icon,
                         resize_to_fill: [48, 48],
                         format: :webp,
                         saver: { quality: 80 },
                         preprocessed: true
      attachable.variant :thumbnail,
                         resize_to_fill: [128, 128],
                         format: :webp,
                         saver: { quality: 80 },
                         preprocessed: true
      attachable.variant :display,
                         resize_to_limit: [512, 512],
                         format: :webp,
                         saver: { quality: 85 },
                         preprocessed: true
    end
  end
end
