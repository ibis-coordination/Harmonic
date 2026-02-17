# typed: false

require "test_helper"

class AttachmentTest < ActiveSupport::TestCase
  def setup
    @tenant = Tenant.create!(subdomain: "attach-test-#{SecureRandom.hex(4)}", name: "Test Tenant")
    @user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "human")
    @collective = Collective.create!(tenant: @tenant, created_by: @user, name: "Test Studio", handle: "test-studio-#{SecureRandom.hex(4)}")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.set_thread_context(@collective)
    @note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Test Note",
      text: "Test content"
    )
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  # Helper to create a valid PNG file (1x1 transparent pixel)
  def valid_png_bytes
    # Minimal valid PNG: 1x1 transparent pixel
    "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82".b
  end

  # Helper to create valid JPEG bytes
  def valid_jpeg_bytes
    "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00".b
  end

  # Helper to create valid PDF bytes
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

  # ============================================
  # Filename Sanitization Tests
  # ============================================

  test "sanitizes path traversal attempts in filename" do
    blob = create_blob(content: "test content", filename: "etc_passwd", content_type: "text/plain")
    attachment = Attachment.create!(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Test the sanitize_filename method directly
    sanitized = attachment.send(:sanitize_filename, "../../../etc/passwd")
    assert_not_includes sanitized, ".."
    assert_not_includes sanitized, "/"
    assert_equal "etc_passwd", sanitized
  ensure
    attachment&.destroy
  end

  test "sanitizes backslash path traversal in filename" do
    blob = create_blob(content: "test content", filename: "config", content_type: "text/plain")
    attachment = Attachment.create!(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Test the sanitize_filename method directly
    sanitized = attachment.send(:sanitize_filename, "..\\..\\windows\\system32\\config")
    assert_not_includes sanitized, ".."
    assert_not_includes sanitized, "\\"
  ensure
    attachment&.destroy
  end

  test "sanitizes null bytes in filename" do
    blob = create_blob(content: "test content", filename: "file.txt", content_type: "text/plain")
    attachment = Attachment.create!(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Test the sanitize_filename method directly (can't create blob with null bytes)
    sanitized = attachment.send(:sanitize_filename, "file\x00.txt")
    assert_not_includes sanitized, "\x00"
    assert_equal "file.txt", sanitized
  ensure
    attachment&.destroy
  end

  test "handles empty filename after sanitization" do
    blob = create_blob(content: "test content", filename: "test.txt", content_type: "text/plain")
    attachment = Attachment.create!(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Test the sanitize_filename method directly
    sanitized = attachment.send(:sanitize_filename, "../..")
    assert_equal "unnamed", sanitized
  ensure
    attachment&.destroy
  end

  test "truncates long filenames while preserving extension" do
    long_name = "a" * 300 + ".txt"
    blob = create_blob(content: "test content", filename: long_name, content_type: "text/plain")
    attachment = Attachment.create!(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert attachment.name.length <= Attachment::MAX_FILENAME_LENGTH
    assert attachment.name.end_with?(".txt")
  ensure
    attachment&.destroy
  end

  # ============================================
  # Magic Byte Validation Tests
  # ============================================

  test "accepts valid PNG with correct magic bytes" do
    blob = create_blob(content: valid_png_bytes, filename: "image.png", content_type: "image/png")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert attachment.valid?, "PNG with valid magic bytes should be valid: #{attachment.errors.full_messages}"
  end

  test "rejects PNG with wrong magic bytes" do
    # Create a file that claims to be PNG but has text content
    blob = create_blob(content: "This is not a PNG file", filename: "fake.png", content_type: "image/png")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert_not attachment.valid?
    assert attachment.errors[:file].any? { |e| e.include?("content does not match") }
  end

  test "accepts valid PDF with correct magic bytes" do
    blob = create_blob(content: valid_pdf_bytes, filename: "document.pdf", content_type: "application/pdf")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert attachment.valid?, "PDF with valid magic bytes should be valid: #{attachment.errors.full_messages}"
  end

  test "rejects PDF with wrong magic bytes" do
    blob = create_blob(content: "Not a PDF file", filename: "fake.pdf", content_type: "application/pdf")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert_not attachment.valid?
    assert attachment.errors[:file].any? { |e| e.include?("content does not match") }
  end

  test "accepts text files without magic byte check" do
    # Text files don't have reliable magic bytes, so we skip validation
    blob = create_blob(content: "Plain text content", filename: "document.txt", content_type: "text/plain")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert attachment.valid?, "Text files should be valid: #{attachment.errors.full_messages}"
  end

  # ============================================
  # File Type Restriction Tests
  # ============================================

  test "rejects executable file types" do
    blob = create_blob(content: "MZ\x90\x00", filename: "malware.exe", content_type: "application/x-msdownload")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert_not attachment.valid?
    assert attachment.errors[:files].any? { |e| e.include?("acceptable file type") }
  end

  test "rejects JavaScript file types" do
    blob = create_blob(content: "alert('xss')", filename: "script.js", content_type: "application/javascript")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert_not attachment.valid?
    assert attachment.errors[:files].any? { |e| e.include?("acceptable file type") }
  end

  # ============================================
  # File Size Limit Tests
  # ============================================

  test "rejects files over 10MB" do
    large_content = "x" * (11 * 1024 * 1024) # 11MB
    blob = create_blob(content: large_content, filename: "large.txt", content_type: "text/plain")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    assert_not attachment.valid?
    assert attachment.errors[:files].any? { |e| e.include?("less than 10MB") }
  end

  # ============================================
  # Virus Scanning Tests
  # ============================================

  test "virus_scanning_enabled? returns false in test environment" do
    blob = create_blob(content: "test content", filename: "test.txt", content_type: "text/plain")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # In test environment, virus scanning should be disabled by default
    assert_not attachment.send(:virus_scanning_enabled?)
  end

  test "scan_for_viruses is called during validation" do
    blob = create_blob(content: "test content", filename: "test.txt", content_type: "text/plain")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Mock the scan_for_viruses to verify it gets called
    scan_called = false
    attachment.define_singleton_method(:scan_for_viruses) do
      scan_called = true
    end

    attachment.valid?
    assert scan_called, "scan_for_viruses should be called during validation"
  end

  test "scan_for_viruses adds error when virus detected" do
    blob = create_blob(content: "test content", filename: "test.txt", content_type: "text/plain")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Stub virus_scanning_enabled? to return true
    attachment.define_singleton_method(:virus_scanning_enabled?) { true }

    # Mock Clamby.safe? to return false (virus detected)
    original_safe = Clamby.method(:safe?)
    Clamby.define_singleton_method(:safe?) { |_path| false }

    begin
      attachment.send(:scan_for_viruses)
      assert attachment.errors[:file].any? { |e| e.include?("virus") }
    ensure
      Clamby.define_singleton_method(:safe?, original_safe)
    end
  end

  test "scan_for_viruses does not add error for clean files" do
    blob = create_blob(content: "test content", filename: "test.txt", content_type: "text/plain")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Stub virus_scanning_enabled? to return true
    attachment.define_singleton_method(:virus_scanning_enabled?) { true }

    # Mock Clamby.safe? to return true (clean file)
    original_safe = Clamby.method(:safe?)
    Clamby.define_singleton_method(:safe?) { |_path| true }

    begin
      attachment.send(:scan_for_viruses)
      assert_not attachment.errors[:file].any? { |e| e.include?("virus") }
    ensure
      Clamby.define_singleton_method(:safe?, original_safe)
    end
  end

  test "scan_for_viruses handles errors gracefully" do
    blob = create_blob(content: "test content", filename: "test.txt", content_type: "text/plain")
    attachment = Attachment.new(
      tenant: @tenant,
      collective: @collective,
      attachable: @note,
      file: blob,
      created_by: @user,
      updated_by: @user
    )

    # Stub virus_scanning_enabled? to return true
    attachment.define_singleton_method(:virus_scanning_enabled?) { true }

    # Mock Clamby.safe? to raise an error
    original_safe = Clamby.method(:safe?)
    Clamby.define_singleton_method(:safe?) { |_path| raise StandardError, "ClamAV unavailable" }

    begin
      # Should not raise - error should be logged and handled gracefully
      assert_nothing_raised do
        attachment.send(:scan_for_viruses)
      end

      # Should not add virus error when scanning fails
      assert_not attachment.errors[:file].any? { |e| e.include?("virus") }
    ensure
      Clamby.define_singleton_method(:safe?, original_safe)
    end
  end
end
