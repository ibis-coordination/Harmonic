# typed: true
# frozen_string_literal: true

# Shim for Sidekiq::Scheduled module which is defined at runtime
# but not fully captured by tapioca
module Sidekiq
  module Scheduled
    class Poller
    end
  end
end
