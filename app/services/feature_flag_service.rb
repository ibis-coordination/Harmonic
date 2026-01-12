# typed: true

class FeatureFlagService
  extend T::Sig

  # Load and cache the feature flags configuration
  sig { returns(T::Hash[String, T.untyped]) }
  def self.config
    @config ||= begin
      yaml = YAML.load_file(Rails.root.join("config/feature_flags.yml"))
      yaml["feature_flags"] || {}
    end
  end

  # Reset cached config (useful for testing)
  sig { void }
  def self.reset_config!
    @config = nil
  end

  # List all available feature flag names
  sig { returns(T::Array[String]) }
  def self.all_flags
    config.keys
  end

  # Get metadata for a specific flag
  sig { params(flag_name: String).returns(T.nilable(T::Hash[String, T.untyped])) }
  def self.flag_metadata(flag_name)
    config[flag_name.to_s]
  end

  # Check if a flag is enabled at the app level (from config file)
  sig { params(flag_name: String).returns(T::Boolean) }
  def self.app_enabled?(flag_name)
    metadata = flag_metadata(flag_name)
    return false if metadata.nil?

    metadata["app_enabled"] == true
  end

  # Get the default value for a tenant
  sig { params(flag_name: String).returns(T::Boolean) }
  def self.default_for_tenant(flag_name)
    metadata = flag_metadata(flag_name)
    return false if metadata.nil?

    metadata["default_tenant"] == true
  end

  # Get the default value for a studio
  sig { params(flag_name: String).returns(T::Boolean) }
  def self.default_for_studio(flag_name)
    metadata = flag_metadata(flag_name)
    return false if metadata.nil?

    metadata["default_studio"] == true
  end

  # Check if a flag is enabled at the tenant level (considering cascade from app)
  sig { params(tenant: Tenant, flag_name: String).returns(T::Boolean) }
  def self.tenant_enabled?(tenant, flag_name)
    # Must be enabled at app level first
    return false unless app_enabled?(flag_name)

    # Check tenant's local setting
    tenant.feature_flag_enabled_locally?(flag_name)
  end

  # Check if a flag is enabled at the studio level (considering cascade from tenant)
  sig { params(studio: Studio, flag_name: String).returns(T::Boolean) }
  def self.studio_enabled?(studio, flag_name)
    # Must be enabled at tenant level (which includes app level check)
    return false unless tenant_enabled?(T.must(studio.tenant), flag_name)

    # Check studio's local setting
    studio.feature_flag_enabled_locally?(flag_name)
  end

  # Main entry point: check if a feature is enabled at the appropriate level
  # If only tenant is provided, checks tenant level
  # If studio is provided, checks studio level (which cascades through tenant and app)
  sig do
    params(
      flag_name: String,
      tenant: T.nilable(Tenant),
      studio: T.nilable(Studio)
    ).returns(T::Boolean)
  end
  def self.enabled?(flag_name, tenant: nil, studio: nil)
    if studio
      studio_enabled?(studio, flag_name)
    elsif tenant
      tenant_enabled?(tenant, flag_name)
    else
      app_enabled?(flag_name)
    end
  end
end
