# typed: false

require "test_helper"

class EmailConfirmationMailerTest < ActiveSupport::TestCase
  setup do
    @tenant = create_tenant(subdomain: "mailer-ec-#{SecureRandom.hex(4)}", name: "EC Mailer")
    @host = create_user(email: "echost-#{SecureRandom.hex(4)}@example.com", name: "EC Host")
    @tenant.add_user!(@host)
    @tenant.create_main_collective!(created_by: @host)
    @identity = OmniAuthIdentity.create!(
      user: @host, email: @host.email, name: @host.name,
      password: "validpassword123", password_confirmation: "validpassword123",
    )
    @raw_token = @identity.send_email_confirmation!
  end

  test "confirm email has correct subject and recipient" do
    email = EmailConfirmationMailer.confirm(@identity, @raw_token, @tenant)

    assert_equal [@identity.email], email.to
    assert_match(/confirm/i, email.subject)
  end

  test "confirm email body contains a /confirm-email/:token URL that routes correctly" do
    email = EmailConfirmationMailer.confirm(@identity, @raw_token, @tenant)
    body = email.body.encoded

    href = T.must(body.match(%r{(https?://[^"\s>]+/confirm-email/[^"\s>]+)}))[1]
    path = URI.parse(href).path

    routed = Rails.application.routes.recognize_path(path, method: :get)
    assert_equal "email_confirmations", routed[:controller]
    assert_equal "confirm", routed[:action]
    assert_equal @raw_token, routed[:token]
  end

  test "confirm uses the tenant subdomain in the URL" do
    email = EmailConfirmationMailer.confirm(@identity, @raw_token, @tenant)
    assert_match(/#{@tenant.subdomain}\./, email.body.encoded,
                 "expected mailer URL to be scoped to the tenant's subdomain")
  end
end
