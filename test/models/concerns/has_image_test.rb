# typed: false

require "test_helper"
require "vips"

class HasImageTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant(subdomain: "hasimg-#{SecureRandom.hex(4)}")
    @user = create_user(email: "hasimg_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  def synthetic_image_tempfile(width:, height:, format: "png")
    image = Vips::Image.black(width, height) + [128, 64, 200] # tint so it's not pure black
    tempfile = Tempfile.new(["synthetic_#{width}x#{height}", ".#{format}"])
    tempfile.close
    image.write_to_file(tempfile.path)
    tempfile
  end

  test "image_path returns nil when no image attached" do
    assert_nil @user.image_path
    assert_nil @user.image_path(variant: :icon)
    assert_nil @user.image_path(variant: :thumbnail)
    assert_nil @user.image_path(variant: :display)
  end

  test "image_path with no variant returns the original blob url when attached" do
    tempfile = synthetic_image_tempfile(width: 100, height: 100)
    @user.image.attach(io: File.open(tempfile.path), filename: "small.png")
    assert_match(%r{/rails/active_storage/blobs/}, @user.image_path)
  end

  test "image_path with a known variant returns a representation url" do
    tempfile = synthetic_image_tempfile(width: 200, height: 200)
    @user.image.attach(io: File.open(tempfile.path), filename: "v.png")
    [:icon, :thumbnail, :display].each do |variant|
      url = @user.image_path(variant: variant)
      assert_match(%r{/rails/active_storage/representations/}, url, "variant #{variant} url")
    end
  end

  test "image_path with an unknown variant raises" do
    tempfile = synthetic_image_tempfile(width: 100, height: 100)
    @user.image.attach(io: File.open(tempfile.path), filename: "v.png")
    assert_raises(ArgumentError) { @user.image_path(variant: :nonsense) }
  end

  test "cropped_image_data= resizes source larger than 1024 down to within 1024" do
    big = synthetic_image_tempfile(width: 2000, height: 2000)
    png_bytes = File.binread(big.path)
    data_url = "data:image/png;base64,#{Base64.strict_encode64(png_bytes)}"

    @user.cropped_image_data = data_url
    @user.reload
    blob = @user.image.blob
    blob.analyze unless blob.analyzed?

    assert blob.metadata["width"] <= 1024, "expected width <= 1024, got #{blob.metadata["width"]}"
    assert blob.metadata["height"] <= 1024, "expected height <= 1024, got #{blob.metadata["height"]}"
  end

  test "cropped_image_data= leaves source smaller than 1024 unchanged" do
    small = synthetic_image_tempfile(width: 500, height: 500)
    png_bytes = File.binread(small.path)
    data_url = "data:image/png;base64,#{Base64.strict_encode64(png_bytes)}"

    @user.cropped_image_data = data_url
    @user.reload
    blob = @user.image.blob
    blob.analyze unless blob.analyzed?

    assert_equal 500, blob.metadata["width"]
    assert_equal 500, blob.metadata["height"]
  end

  test "cropped_image_data= rejects payloads over MAX_SOURCE_BYTES" do
    oversized = "a" * ((HasImage::MAX_SOURCE_BYTES * 4 / 3) + 100)
    assert_raises(ArgumentError) do
      @user.cropped_image_data = "data:image/png;base64,#{oversized}"
    end
    assert_not @user.image.attached?
  end

  test "cropped_image_data= rejects non-image bytes" do
    bytes = "this is not an image, just text bytes" * 100
    data_url = "data:image/png;base64,#{Base64.strict_encode64(bytes)}"
    assert_raises(ArgumentError) do
      @user.cropped_image_data = data_url
    end
    assert_not @user.image.attached?
  end

  test "image_url= rejects loopback addresses" do
    @user.image_url = "http://127.0.0.1/avatar.png"
    assert_not @user.image.attached?

    @user.image_url = "http://localhost/avatar.png"
    assert_not @user.image.attached?
  end

  test "image_url= rejects private network addresses" do
    [
      "http://10.0.0.1/x.png",
      "http://192.168.1.1/x.png",
      "http://172.16.0.1/x.png",
    ].each do |url|
      @user.image_url = url
      assert_not @user.image.attached?, "expected to refuse #{url}"
    end
  end

  test "image_url= rejects link-local (cloud metadata) addresses" do
    @user.image_url = "http://169.254.169.254/latest/meta-data/"
    assert_not @user.image.attached?
  end

  test "image_url= rejects 0.0.0.0 (functionally localhost on Linux)" do
    @user.image_url = "http://0.0.0.0/x.png"
    assert_not @user.image.attached?
  end

  test "image_url= rejects IPv6 loopback and link-local literals" do
    [
      "http://[::1]/x.png",
      "http://[fe80::1]/x.png",
      "http://[::]/x.png",
    ].each do |url|
      @user.image_url = url
      assert_not @user.image.attached?, "expected to refuse #{url}"
    end
  end

  test "image_url= rejects IPv4-mapped IPv6 loopback/private" do
    [
      "http://[::ffff:127.0.0.1]/x.png",
      "http://[::ffff:10.0.0.1]/x.png",
      "http://[::ffff:169.254.169.254]/x.png",
    ].each do |url|
      @user.image_url = url
      assert_not @user.image.attached?, "expected to refuse #{url}"
    end
  end

  test "image_url= rejects non-http schemes" do
    @user.image_url = "file:///etc/passwd"
    assert_not @user.image.attached?

    @user.image_url = "javascript:alert(1)"
    assert_not @user.image.attached?
  end

  test "image_url= silently ignores unresolvable hosts" do
    @user.image_url = "http://this-host-does-not-exist-#{SecureRandom.hex(4)}.invalid/x.png"
    assert_not @user.image.attached?
  end

  test "attach_bounded_image! works on an unpersisted record" do
    tempfile = synthetic_image_tempfile(width: 100, height: 100)
    new_user = User.new(email: "deferred_#{SecureRandom.hex(4)}@example.com", name: "Deferred", user_type: "human")
    File.open(tempfile.path) do |f|
      new_user.attach_bounded_image!(f, filename: "x.png")
    end
    new_user.save!
    assert new_user.image.attached?
    assert_nothing_raised { new_user.image.download }
  end

  test "parse_safe_external_uri accepts a public host" do
    # We can't make an actual network call in tests, but we can verify
    # the URL passes the SSRF validator (returns a URI, not nil).
    @user.send(:parse_safe_external_uri, "https://example.com/foo.png").tap do |uri|
      assert uri.is_a?(URI), "expected a URI for a public host, got #{uri.inspect}"
    end
  end
end
