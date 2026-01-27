# typed: true
# frozen_string_literal: true

# Rails.logger is typically wrapped with ActiveSupport::TaggedLogging,
# which adds the `tagged` method. This shim tells Sorbet about it.
class ActiveSupport::Logger
  sig { params(tags: T.untyped, block: T.proc.void).void }
  def tagged(*tags, &block); end
end
