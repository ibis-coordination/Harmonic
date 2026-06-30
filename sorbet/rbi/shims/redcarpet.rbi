# typed: true

# Redcarpet's plain-text renderer lives in `redcarpet/render_strip`, which the
# gem does not require by default — so it isn't loaded when tapioca generates
# the gem RBI and is therefore absent from it. MentionParser requires the file
# explicitly and subclasses StripDown, so declare the constant here.
module Redcarpet
  module Render
    # rubocop:disable Lint/EmptyClass
    class StripDown < ::Redcarpet::Render::Base; end
    # rubocop:enable Lint/EmptyClass
  end
end
