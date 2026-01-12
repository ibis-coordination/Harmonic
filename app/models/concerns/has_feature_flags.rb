# typed: false

# Shared feature flag functionality for Tenant and Studio models
module HasFeatureFlags
  extend ActiveSupport::Concern

  # Get the feature_flags hash from settings
  def feature_flags_hash
    settings["feature_flags"] || {}
  end

  # Check if a flag is enabled at this level only (ignores cascade)
  def feature_flag_enabled_locally?(flag_name)
    value = feature_flags_hash[flag_name.to_s]
    # If not explicitly set, use the default from config
    if value.nil?
      default_method = is_a?(Studio) ? :default_for_studio : :default_for_tenant
      return FeatureFlagService.send(default_method, flag_name)
    end
    value.to_s == "true"
  end

  # Set a feature flag at this level
  def set_feature_flag!(flag_name, value)
    self.settings ||= {}
    self.settings["feature_flags"] ||= {}
    self.settings["feature_flags"][flag_name.to_s] = value
    save!
  end

  # Enable a feature flag at this level
  def enable_feature_flag!(flag_name)
    set_feature_flag!(flag_name, true)
  end

  # Disable a feature flag at this level
  def disable_feature_flag!(flag_name)
    set_feature_flag!(flag_name, false)
  end
end
