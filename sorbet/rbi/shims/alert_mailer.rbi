# typed: true
# frozen_string_literal: true

# ActionMailer methods are defined as instance methods but called as class methods.
# Rails uses method_missing to delegate. This shim tells Sorbet about the class method.
class AlertMailer
  class << self
    sig { params(recipients: T::Array[String], subject: String, payload: T::Hash[Symbol, T.untyped]).returns(ActionMailer::MessageDelivery) }
    def critical_alert(recipients:, subject:, payload:); end
  end
end
