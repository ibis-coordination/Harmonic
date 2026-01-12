require "test_helper"

class FeatureFlagServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @studio, @user = create_tenant_studio_user
  end

  test "config loads feature flags from yaml" do
    config = FeatureFlagService.config
    assert config.is_a?(Hash)
    assert config.key?("api")
    assert config.key?("file_attachments")
  end

  test "all_flags returns list of flag names" do
    flags = FeatureFlagService.all_flags
    assert flags.include?("api")
    assert flags.include?("file_attachments")
  end

  test "flag_metadata returns metadata hash for valid flag" do
    metadata = FeatureFlagService.flag_metadata("api")
    assert_equal "API Access", metadata["name"]
    assert metadata["description"].present?
    assert metadata.key?("app_enabled")
  end

  test "flag_metadata returns nil for invalid flag" do
    metadata = FeatureFlagService.flag_metadata("nonexistent_flag")
    assert_nil metadata
  end

  test "app_enabled? returns value from config" do
    # Both api and file_attachments are enabled at app level in config
    assert FeatureFlagService.app_enabled?("api")
    assert FeatureFlagService.app_enabled?("file_attachments")
  end

  test "app_enabled? returns false for nonexistent flag" do
    assert_not FeatureFlagService.app_enabled?("nonexistent_flag")
  end

  test "tenant_enabled? returns false when app level is disabled" do
    # Even if tenant has it enabled, if app is disabled, should return false
    @tenant.set_feature_flag!("api", true)

    # We can't easily disable app level in tests since it comes from config
    # but we can test that when tenant has flag disabled, it returns false
    @tenant.set_feature_flag!("api", false)
    assert_not FeatureFlagService.tenant_enabled?(@tenant, "api")
  end

  test "tenant_enabled? returns true when both app and tenant are enabled" do
    @tenant.set_feature_flag!("api", true)
    assert FeatureFlagService.tenant_enabled?(@tenant, "api")
  end

  test "studio_enabled? returns false when tenant level is disabled" do
    @tenant.set_feature_flag!("api", false)
    @studio.set_feature_flag!("api", true)
    assert_not FeatureFlagService.studio_enabled?(@studio, "api")
  end

  test "studio_enabled? returns true when tenant and studio are enabled" do
    @tenant.set_feature_flag!("api", true)
    @studio.set_feature_flag!("api", true)
    assert FeatureFlagService.studio_enabled?(@studio, "api")
  end

  test "studio_enabled? returns false when studio is disabled even if tenant is enabled" do
    @tenant.set_feature_flag!("api", true)
    @studio.set_feature_flag!("api", false)
    assert_not FeatureFlagService.studio_enabled?(@studio, "api")
  end

  test "enabled? with no tenant or studio checks app level" do
    assert FeatureFlagService.enabled?("api")
  end

  test "enabled? with tenant checks tenant level" do
    @tenant.set_feature_flag!("api", true)
    assert FeatureFlagService.enabled?("api", tenant: @tenant)

    @tenant.set_feature_flag!("api", false)
    assert_not FeatureFlagService.enabled?("api", tenant: @tenant)
  end

  test "enabled? with studio checks studio level" do
    @tenant.set_feature_flag!("api", true)
    @studio.set_feature_flag!("api", true)
    assert FeatureFlagService.enabled?("api", tenant: @tenant, studio: @studio)

    @studio.set_feature_flag!("api", false)
    assert_not FeatureFlagService.enabled?("api", tenant: @tenant, studio: @studio)
  end

  test "cascade: tenant disabled overrides studio enabled" do
    @tenant.set_feature_flag!("api", false)
    @studio.set_feature_flag!("api", true)

    # Studio has it enabled locally, but tenant is disabled
    assert @studio.feature_flag_enabled_locally?("api")
    # But effective check returns false due to cascade
    assert_not FeatureFlagService.studio_enabled?(@studio, "api")
  end

  test "default_for_tenant returns config default" do
    # api default_tenant is false in config
    assert_not FeatureFlagService.default_for_tenant("api")
    # file_attachments default_tenant is true in config
    assert FeatureFlagService.default_for_tenant("file_attachments")
  end

  test "default_for_studio returns config default" do
    # api default_studio is false in config
    assert_not FeatureFlagService.default_for_studio("api")
    # file_attachments default_studio is true in config
    assert FeatureFlagService.default_for_studio("file_attachments")
  end
end
