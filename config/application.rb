require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RailsRuby3
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Opt out of `executor_around_test_case`: wrapping the whole test in a
    # Rails executor block makes the per-request `executor.wrap` reentrant,
    # which suppresses the `to_complete` callbacks that reset
    # CurrentAttributes between requests. That breaks tests asserting that
    # per-request state (e.g. AutomationContext) is cleared at request
    # boundaries — behavior we rely on in production.
    config.active_support.executor_around_test_case = false

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    config.active_record.schema_format = :sql
    config.active_job.queue_adapter = :sidekiq

    # Autoload the OmniAuthBotProtection middleware; it's registered in
    # config/initializers/omniauth.rb (must precede OmniAuth::Builder).
    config.autoload_paths << Rails.root.join("app/middleware")

    # ActiveStorage signed_id URLs (rails_blob_path / rails_blob_url) expire after 1 hour.
    # Limits the leak window if a URL is shared outside the auth boundary.
    # Sensitive attachments (data exports) use shorter explicit TTLs at the call site.
    config.active_storage.urls_expire_in = 1.hour
  end
end
