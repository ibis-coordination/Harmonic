# typed: false
# frozen_string_literal: true

# Configure Sidekiq server and handle development mode eager loading.
#
# In development mode, Rails uses lazy class loading (eager_load: false).
# When multiple Sidekiq threads try to autoload classes simultaneously,
# Zeitwerk's ReentrantReadWriteLock can get corrupted, causing:
#   "Concurrent::IllegalOperationError: Cannot release a read lock which is not held"
#
# The fix is to force eager loading when Sidekiq starts in development mode.
# This ensures all classes are loaded before any jobs run, preventing
# the concurrent autoloading race condition.

Sidekiq.configure_server do |config|
  # Use the startup event to eager load after Rails is fully initialized
  config.on(:startup) do
    # In development mode, force eager loading to prevent Zeitwerk lock corruption
    # when multiple threads try to autoload classes simultaneously.
    if Rails.env.development? && !Rails.application.config.eager_load
      Rails.logger.info("[Sidekiq] Force eager loading application code in development mode")
      Rails.application.eager_load!
    end
  end
end
