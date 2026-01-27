# typed: true
# frozen_string_literal: true

# AlertMailer sends email notifications for critical alerts.
# Configured via ALERT_EMAIL_RECIPIENTS environment variable.
class AlertMailer < ApplicationMailer
  extend T::Sig

  sig { params(recipients: T::Array[String], subject: String, payload: T::Hash[Symbol, T.untyped]).returns(Mail::Message) }
  def critical_alert(recipients:, subject:, payload:)
    @payload = payload
    @message = payload[:message]
    @severity = payload[:severity]
    @timestamp = payload[:timestamp]
    @environment = payload[:environment]
    @hostname = payload[:hostname]
    @context = payload[:context]

    mail(
      to: recipients,
      subject: subject
    )
  end
end
