# typed: false

require "test_helper"

class MediaItemTest < ActiveSupport::TestCase
  def setup
    @tenant = Tenant.create!(subdomain: "media-test-#{SecureRandom.hex(4)}", name: "Test Tenant")
    @user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "human")
    @collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Test Collective",
      handle: "media-test-collective-#{SecureRandom.hex(4)}"
    )
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    @note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Note with media",
      text: "Body text"
    )
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def valid_png_bytes
    "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82".b
  end

  def valid_jpeg_bytes
    "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00".b
  end

  def valid_pdf_bytes
    "%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n".b
  end

  def create_blob(content:, filename:, content_type:)
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content),
      filename: filename,
      content_type: content_type
    )
  end

  def build_media_item(blob:, **overrides)
    MediaItem.new({
      tenant: @tenant,
      collective: @collective,
      mediable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user,
    }.merge(overrides))
  end

  # ============================================================
  # Validations
  # ============================================================

  test "accepts a valid PNG image" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob)
    assert item.valid?, item.errors.full_messages.inspect
  end

  test "accepts a valid JPEG image" do
    blob = create_blob(content: valid_jpeg_bytes, filename: "a.jpg", content_type: "image/jpeg")
    item = build_media_item(blob: blob)
    assert item.valid?, item.errors.full_messages.inspect
  end

  test "rejects PDF (not an allowed image type)" do
    blob = create_blob(content: valid_pdf_bytes, filename: "doc.pdf", content_type: "application/pdf")
    item = build_media_item(blob: blob)
    assert_not item.valid?
    assert(item.errors[:file].any? { |e| e.include?("image") || e.include?("type") })
  end

  test "rejects text content type" do
    blob = create_blob(content: "Plain text", filename: "note.txt", content_type: "text/plain")
    item = build_media_item(blob: blob)
    assert_not item.valid?
  end

  test "rejects PNG with mismatched magic bytes" do
    blob = create_blob(content: "not actually a png", filename: "fake.png", content_type: "image/png")
    item = build_media_item(blob: blob)
    assert_not item.valid?
    assert(item.errors[:file].any? { |e| e.include?("content does not match") })
  end

  test "rejects RIFF-container file (e.g. WAV) masquerading as WebP" do
    # WAV file: RIFF + 4-byte size + "WAVE" tag. Same first 4 bytes as WebP
    # but different tag at offset 8. Bypass Marcel's content-type sniffing
    # (which would correctly catch this on its own) so the test isolates
    # the magic-byte check — that's the defense-in-depth layer guarding
    # against Marcel being fooled by a crafted file.
    wav = "RIFF\x00\x00\x00\x10WAVEfmt ".b
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(wav),
      filename: "audio.webp",
      content_type: "image/webp",
      identify: false
    )
    item = build_media_item(blob: blob)
    assert_not item.valid?
    assert(item.errors[:file].any? { |e| e.include?("content does not match") },
           "expected magic-byte rejection, got #{item.errors.full_messages.inspect}")
  end

  test "accepts a proper WebP with RIFF + WEBP signature" do
    # Minimal valid WebP header: "RIFF" + 4-byte length + "WEBP" + chunk
    webp = "RIFF\x1a\x00\x00\x00WEBPVP8L\x0d\x00\x00\x00\x2f\x00".b
    blob = create_blob(content: webp, filename: "a.webp", content_type: "image/webp")
    item = build_media_item(blob: blob)
    assert item.valid?, item.errors.full_messages.inspect
  end

  test "rejects files over the per-file size limit" do
    big = "x" * (MediaItem::MAX_FILE_BYTES + 1)
    blob = create_blob(content: big, filename: "big.png", content_type: "image/png")
    item = build_media_item(blob: blob)
    assert_not item.valid?
    assert(item.errors[:file].any? { |e| e.include?("must be less than") })
  end

  test "requires a file" do
    item = MediaItem.new(
      tenant: @tenant,
      collective: @collective,
      mediable: @note,
      created_by: @user,
      updated_by: @user,
    )
    assert_not item.valid?
    assert_includes item.errors.full_messages.join, "File"
  end

  # ============================================================
  # Persistence + metadata
  # ============================================================

  test "set_file_metadata populates content_type and byte_size on save" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob)
    item.save!
    assert_equal "image/png", item.content_type
    assert_equal valid_png_bytes.bytesize, item.byte_size
  end

  test "default display_order is 0 for first item" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob)
    item.save!
    assert_equal 0, item.display_order
  end

  test "alt_text is optional" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob, alt_text: "A test photo")
    assert item.valid?
    item.save!
    assert_equal "A test photo", item.alt_text
  end

  test "rejects alt_text longer than MAX_ALT_TEXT_LENGTH" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    too_long = "x" * (MediaItem::MAX_ALT_TEXT_LENGTH + 1)
    item = build_media_item(blob: blob, alt_text: too_long)
    assert_not item.valid?
    assert item.errors[:alt_text].any?
  end

  test "rejects caption longer than MAX_CAPTION_LENGTH" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    too_long = "x" * (MediaItem::MAX_CAPTION_LENGTH + 1)
    item = build_media_item(blob: blob, caption: too_long)
    assert_not item.valid?
    assert item.errors[:caption].any?
  end

  test "url raises ArgumentError for unknown variant" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob)
    item.save!
    assert_raises(ArgumentError) { item.url(variant: :nonsense) }
  end

  test "alt_text_for_markdown escapes markdown control chars" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob, alt_text: "evil ](javascript:alert(1) ['x'](http://e)")
    item.save!(validate: false) # bypass length validation for crafted input
    out = item.alt_text_for_markdown
    refute_includes out, "](javascript", "raw injection should be neutralized"
    assert_includes out, "\\]"
    assert_includes out, "\\("
    assert_includes out, "\\)"
  end

  test "alt_text_for_markdown collapses newlines so syntax stays single-line" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob, alt_text: "line1\nline2")
    item.save!
    assert_equal "line1 line2", item.alt_text_for_markdown
  end

  # ============================================================
  # Note association
  # ============================================================

  test "note has many media_items ordered by display_order" do
    b1 = create_blob(content: valid_png_bytes, filename: "1.png", content_type: "image/png")
    b2 = create_blob(content: valid_png_bytes, filename: "2.png", content_type: "image/png")
    b3 = create_blob(content: valid_png_bytes, filename: "3.png", content_type: "image/png")
    second = build_media_item(blob: b2, display_order: 1)
    second.save!
    third = build_media_item(blob: b3, display_order: 2)
    third.save!
    first = build_media_item(blob: b1, display_order: 0)
    first.save!
    @note.reload
    assert_equal [first.id, second.id, third.id], @note.media_items.map(&:id)
  end

  test "media items are destroyed with the note" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = build_media_item(blob: blob)
    item.save!
    assert MediaItem.exists?(item.id)
    @note.destroy!
    assert_not MediaItem.exists?(item.id)
  end

  # ============================================================
  # Tenant/collective scoping
  # ============================================================

  test "tenant and collective default from thread context" do
    blob = create_blob(content: valid_png_bytes, filename: "a.png", content_type: "image/png")
    item = MediaItem.new(mediable: @note, file: blob, created_by: @user, updated_by: @user)
    item.save!
    assert_equal @tenant.id, item.tenant_id
    assert_equal @collective.id, item.collective_id
  end
end
