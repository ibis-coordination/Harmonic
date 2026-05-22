# typed: false
require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @tenant = create_tenant(subdomain: "apphelp-#{SecureRandom.hex(4)}")
    @user = create_user(email: "apphelp_#{SecureRandom.hex(4)}@example.com", name: "Alice Smith")
    @tenant.add_user!(@user)
    @collective = create_collective(tenant: @tenant, created_by: @user, handle: "apphelp-c-#{SecureRandom.hex(4)}", name: "Cool Collective")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  # === inline_avatar ===

  test "inline_avatar returns empty string when record is nil" do
    assert_equal "", inline_avatar(nil)
  end

  test "inline_avatar renders span with initials and avatar_color when user has no image" do
    html = inline_avatar(@user)
    assert_match(/<span/, html)
    assert_match(/background-color: #[0-9a-f]{6}/i, html)
    assert_match(/AS<\/span>/, html) # initials from "Alice Smith"
    assert_no_match(/<img/, html)
  end

  test "inline_avatar renders img when user image is attached" do
    fixture_path = Rails.root.join("test/fixtures/files/test.png")
    skip("requires image fixture") unless File.exist?(fixture_path)
    @user.image.attach(io: File.open(fixture_path), filename: "test.png", content_type: "image/png")
    html = inline_avatar(@user)
    assert_match(/<img/, html)
    assert_no_match(/background-color/, html)
  end

  test "inline_avatar uses collective name for initials" do
    html = inline_avatar(@collective)
    assert_match(/CC<\/span>/, html) # initials from "Cool Collective"
  end

  test "inline_avatar always emits the inline-avatar class plus any css_class" do
    html = inline_avatar(@user, css_class: "my-class", style: "width: 32px; height: 32px;")
    assert_match(/class="inline-avatar my-class"/, html)
    assert_match(/width: 32px; height: 32px;/, html)
  end

  test "inline_avatar uses alt as title attribute" do
    html = inline_avatar(@user, alt: "Profile of Alice")
    assert_match(/title="Profile of Alice"/, html)
  end

  test "inline_avatar defaults title to display_name" do
    html = inline_avatar(@user)
    assert_match(/title="Alice Smith"/, html)
  end
end
