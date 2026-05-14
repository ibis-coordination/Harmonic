# typed: false

module Api::V1
  class OptionsController < BaseController
    # Read-only API: index and show inherited from BaseController.
    # Writes go through the markdown UI action routes — see /help/markdown-ui.
  end
end
