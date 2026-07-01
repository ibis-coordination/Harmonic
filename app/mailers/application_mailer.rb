# typed: false

class ApplicationMailer < ActionMailer::Base
  default from: -> { ApplicationMailer.default_from_address }
  layout "mailer"

  # Sender address with a human-friendly display name, e.g.
  # "Harmonic <noreply@harmonic.social>", so inboxes show "Harmonic" instead
  # of a bare "noreply@..." address. If MAILER_FROM_ADDRESS already carries
  # its own display name (contains "<"), it is used verbatim.
  def self.default_from_address
    address = ENV["MAILER_FROM_ADDRESS"].presence || "noreply@harmonic.social"
    return address if address.include?("<")

    name = ENV["MAILER_FROM_NAME"].presence || "Harmonic"
    "#{name} <#{address}>"
  end
end
