# typed: false

class NotificationMailer < ApplicationMailer
  def notification_email(notification_recipient)
    @recipient = notification_recipient
    @notification = notification_recipient.notification
    @user = notification_recipient.user
    @event = @notification.event

    # Build the full URL for the notification link
    @notification_url = build_notification_url(@notification)

    mail(
      to: @user.email,
      subject: @notification.title
    )
  end

  private

  def build_notification_url(notification)
    return nil if notification.url.blank?

    tenant = notification.tenant
    protocol = ENV["HOSTNAME"]&.starts_with?("localhost:") ? "http" : "https"
    subdomain = tenant&.subdomain || ENV.fetch("PRIMARY_SUBDOMAIN", nil)
    hostname = ENV.fetch("HOSTNAME", nil)

    "#{protocol}://#{subdomain}.#{hostname}#{notification.url}"
  end
end
