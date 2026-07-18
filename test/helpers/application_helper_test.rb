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

  # === gateway_vendor_label ===

  test "gateway_vendor_label maps known provider slugs to branded labels" do
    assert_equal "OpenAI", gateway_vendor_label("openai")
    assert_equal "Anthropic", gateway_vendor_label("anthropic")
    assert_equal "DeepSeek", gateway_vendor_label("deepseek")
    assert_equal "xAI", gateway_vendor_label("xai")
    assert_equal "Mistral AI", gateway_vendor_label("mistral")
    assert_equal "Moonshot AI", gateway_vendor_label("moonshot")
    assert_equal "Z.AI", gateway_vendor_label("z-ai")
    assert_equal "Arcee AI", gateway_vendor_label("arcee-ai")
  end

  test "gateway_vendor_label titleizes an unknown provider slug" do
    assert_equal "Some New Provider", gateway_vendor_label("some-new_provider")
    assert_equal "Cohere", gateway_vendor_label("cohere")
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

  # === paid_feature_labels ===

  test "paid_feature_labels includes only Automations when tenant has no personas nor file_attachments" do
    @tenant.set_feature_flag!("trio", false)
    @tenant.set_feature_flag!("file_attachments", false)

    assert_equal ["automations"], paid_feature_labels(@tenant)
  end

  test "paid_feature_labels adds the built-in agents when a persona is tenant-enabled" do
    @tenant.enable_feature_flag!("trio")
    @tenant.set_feature_flag!("file_attachments", false)

    assert_equal ["automations", "the built-in agents (Melody, Counterpoint, and Cadence)"], paid_feature_labels(@tenant)
  end

  test "paid_feature_labels adds file attachments when tenant has it enabled" do
    @tenant.set_feature_flag!("trio", false)
    @tenant.enable_feature_flag!("file_attachments")

    assert_equal ["automations", "file attachments"], paid_feature_labels(@tenant)
  end

  test "paid_feature_labels includes all three when tenant has both flags on" do
    @tenant.enable_feature_flag!("trio")
    @tenant.enable_feature_flag!("file_attachments")

    assert_equal ["automations", "the built-in agents (Melody, Counterpoint, and Cadence)", "file attachments"], paid_feature_labels(@tenant)
  end

  # === paid_features_to_disable_on_downgrade ===

  test "paid_features_to_disable_on_downgrade is empty for a free-tier collective" do
    assert_equal [], paid_features_to_disable_on_downgrade(@collective)
  end

  test "paid_features_to_disable_on_downgrade lists personas the collective has active" do
    @tenant.enable_feature_flag!("trio")
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("trio", true)

    assert_equal ["the built-in agents"], paid_features_to_disable_on_downgrade(@collective)
  end

  test "paid_features_to_disable_on_downgrade lists file attachments when collective has them active" do
    @tenant.enable_feature_flag!("file_attachments")
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("file_attachments", true)

    assert_equal ["file attachments"], paid_features_to_disable_on_downgrade(@collective)
  end

  # === sentence_case ===

  test "sentence_case capitalizes only the first character (preserves product-name casing later in the string)" do
    # Regression: previously used String#capitalize, which downcases everything
    # after the first character — flattening "Trio" mid-sentence to "trio".
    input = "1 enabled automation will be disabled and Trio and file attachments will be turned off"
    assert_equal "1 enabled automation will be disabled and Trio and file attachments will be turned off",
                 sentence_case(input),
                 "sentence_case must leave product-name casing alone after the first character"
  end

  test "sentence_case upcases the first character" do
    assert_equal "File attachments will be turned off", sentence_case("file attachments will be turned off")
  end

  test "sentence_case is a no-op on an empty string" do
    assert_equal "", sentence_case("")
  end

  test "paid_features_to_disable_on_downgrade excludes features the tenant has disabled even if locally set" do
    # Tenant has trio off, so even if the collective's local flag says
    # true, Collective#trio_enabled? returns false via the cascade. The helper must
    # match — we shouldn't tell the user we'll turn off something the tenant
    # never supported.
    @tenant.set_feature_flag!("trio", false)
    @collective.update!(tier: Collective::TIER_PAID)
    @collective.set_feature_flag!("trio", true) # local override, but tenant blocks

    assert_equal [], paid_features_to_disable_on_downgrade(@collective)
  end
end
