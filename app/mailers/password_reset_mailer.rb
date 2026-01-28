# typed: false

class PasswordResetMailer < ApplicationMailer
  # Note: raw_token is the unhashed token that gets sent in the email.
  # The identity stores only a SHA256 hash of the token for security.
  def reset_password_instructions(identity, raw_token)
    @identity = identity
    @reset_url = password_reset_url(token: raw_token)
    mail(
      to: @identity.email,
      from: ENV['MAILER_FROM_ADDRESS'] || 'noreply@harmonic.social',
      subject: "Reset your password on #{ENV['HOSTNAME']}"
    )
  end

  private

  def password_reset_url(token:)
    # Use the auth subdomain for password reset
    protocol = ENV['HOSTNAME'].starts_with?('localhost:') ? 'http' : 'https'
    auth_subdomain = ENV['AUTH_SUBDOMAIN']
    hostname = ENV['HOSTNAME']

    "#{protocol}://#{auth_subdomain}.#{hostname}/password/reset/#{token}"
  end
end
