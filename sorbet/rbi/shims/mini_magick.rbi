# typed: false

# Shim for image_processing gem's MiniMagick backend reference.
# We only use the Vips backend; the mini_magick gem is not installed,
# but image_processing's generated RBI still mentions it.
module MiniMagick
  # rubocop:disable Lint/EmptyClass
  class Tool; end
  # rubocop:enable Lint/EmptyClass
end
