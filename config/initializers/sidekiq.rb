# typed: false
# frozen_string_literal: true

# Sidekiq 7+ includes Rails executor/reloader integration by default.
#
# In development, you may occasionally see:
#   "Concurrent::IllegalOperationError: Cannot release a read lock which is not held"
#
# This is a Zeitwerk race condition when multiple threads autoload classes
# simultaneously after a code change triggers a reload. It's rare and jobs
# retry automatically via Sidekiq's retry mechanism.
#
# If you're actively editing Sidekiq job code and seeing frequent crashes:
#   docker compose restart sidekiq
#
# This is a known Rails/Zeitwerk limitation in development mode.
# Production is unaffected (eager_load: true eliminates the race).
