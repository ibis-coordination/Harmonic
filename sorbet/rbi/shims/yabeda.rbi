# typed: true
# frozen_string_literal: true

# Shim for Yabeda metrics groups defined in config/initializers/yabeda.rb
module Yabeda
  class << self
    sig { returns(T.untyped) }
    def automations; end

    sig { returns(T.untyped) }
    def auth; end

    sig { returns(T.untyped) }
    def content; end

    sig { returns(T.untyped) }
    def api; end

    sig { returns(T.untyped) }
    def security; end

    sig { returns(T.untyped) }
    def users; end
  end
end
