# typed: true

# Deploy identifier, used for per-deploy cache busting (the service worker's
# CACHE_VERSION). Same resolution order as the Sentry release tag.
Rails.application.config.x.git_sha =
  ENV["GIT_SHA"].presence ||
  ENV["RENDER_GIT_COMMIT"].presence ||
  `git rev-parse HEAD 2>/dev/null`.strip.presence ||
  "dev"
