# typed: false

class EmailConfirmationMailer < ApplicationMailer
  def confirm(identity, raw_token, tenant)
    @identity = identity
    @confirm_url = confirm_email_url(raw_token, tenant)
    mail(
      to: identity.email,
      from: ENV["MAILER_FROM_ADDRESS"] || "noreply@harmonic.social",
      subject: "Confirm your email on #{ENV['HOSTNAME']}",
    )
  end

  private

  def confirm_email_url(raw_token, tenant)
    protocol = ENV["HOSTNAME"].to_s.starts_with?("localhost:") ? "http" : "https"
    subdomain = tenant&.subdomain || ENV["PRIMARY_SUBDOMAIN"]
    hostname = ENV["HOSTNAME"]
    "#{protocol}://#{subdomain}.#{hostname}/confirm-email/#{raw_token}"
  end
end
