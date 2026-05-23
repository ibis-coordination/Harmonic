# frozen_string_literal: true

# Replace the route for /rails/active_storage/direct_uploads so the
# endpoint goes through DirectUploadsController (inherits
# ApplicationController) instead of ActiveStorage::DirectUploadsController
# (inherits ActiveStorage::BaseController, which skips all our auth gates).
#
# Why this lives here, not in routes.rb:
#   ActiveStorage::Engine prepends its own routes to the host's route set
#   via a `config.after_initialize` hook. Anything defined in routes.rb
#   loads first, then the engine prepends on top — so the engine wins both
#   the helper-name registration (rails_direct_uploads) and route-match
#   order. The fix is to prepend our route AFTER the engine has prepended
#   its own, which means running in an after_initialize block of our own
#   that gets loaded later. config/initializers/ alphabetically sorts
#   below the engine's railtie initializer for `after_initialize` hook
#   registration order; we use a distinct helper name to avoid the
#   collision entirely.
Rails.application.config.after_initialize do
  Rails.application.routes.prepend do
    post "/rails/active_storage/direct_uploads" => "direct_uploads#create",
         as: :app_direct_uploads
  end
end
