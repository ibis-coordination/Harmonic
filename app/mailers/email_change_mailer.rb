# typed: false

class EmailChangeMailer < ApplicationMailer
  def confirmation(user, raw_token, tenant)
    @user = user
    @confirm_url = email_confirm_url(user, raw_token, tenant)
    mail(
      to: user.pending_email,
      from: ENV["MAILER_FROM_ADDRESS"] || "noreply@harmonic.social",
      subject: "Confirm your new email address on #{ENV['HOSTNAME']}",
    )
  end

  def security_notice(user, tenant)
    @user = user
    @has_password = user.oauth_identities.exists?(provider: "identity")
    @external_providers = user.oauth_identities.where.not(provider: "identity").pluck(:provider).map(&:titleize)
    @login_url = login_url(tenant)
    mail(
      to: user.email,
      from: ENV["MAILER_FROM_ADDRESS"] || "noreply@harmonic.social",
      subject: "Email change requested for your #{ENV['HOSTNAME']} account",
    )
  end

  private

  def email_confirm_url(user, raw_token, tenant)
    protocol = ENV["HOSTNAME"].starts_with?("localhost:") ? "http" : "https"
    subdomain = tenant&.subdomain || ENV["PRIMARY_SUBDOMAIN"]
    hostname = ENV["HOSTNAME"]
    handle = tenant&.tenant_users&.find_by(user: user)&.handle || user.handle

    "#{protocol}://#{subdomain}.#{hostname}/u/#{handle}/settings/email/confirm/#{raw_token}"
  end

  def login_url(tenant)
    protocol = ENV["HOSTNAME"].starts_with?("localhost:") ? "http" : "https"
    subdomain = tenant&.subdomain || ENV["PRIMARY_SUBDOMAIN"]
    hostname = ENV["HOSTNAME"]

    "#{protocol}://#{subdomain}.#{hostname}/login"
  end
end
