class PasswordResetMailer < ApplicationMailer
  def reset_password_instructions(identity)
    @identity = identity
    @reset_url = password_reset_url(token: @identity.reset_password_token)
    mail(
      to: @identity.email,
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
