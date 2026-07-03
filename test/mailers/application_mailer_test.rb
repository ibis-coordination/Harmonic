# typed: false

require "test_helper"

class ApplicationMailerTest < ActiveSupport::TestCase
  def with_env(overrides)
    original = {}
    overrides.each do |key, value|
      original[key] = ENV[key]
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : (ENV[key] = value) }
  end

  test "wraps a bare from address with the default display name" do
    with_env("MAILER_FROM_ADDRESS" => "noreply@example.com", "MAILER_FROM_NAME" => nil) do
      assert_equal "Harmonic <noreply@example.com>", ApplicationMailer.default_from_address
    end
  end

  test "honors a custom MAILER_FROM_NAME" do
    with_env("MAILER_FROM_ADDRESS" => "noreply@example.com", "MAILER_FROM_NAME" => "Acme") do
      assert_equal "Acme <noreply@example.com>", ApplicationMailer.default_from_address
    end
  end

  test "uses the address verbatim when it already carries a display name" do
    with_env("MAILER_FROM_ADDRESS" => "Support <help@example.com>", "MAILER_FROM_NAME" => nil) do
      assert_equal "Support <help@example.com>", ApplicationMailer.default_from_address
    end
  end

  test "falls back to a default address when none is configured" do
    with_env("MAILER_FROM_ADDRESS" => nil, "MAILER_FROM_NAME" => nil) do
      assert_equal "Harmonic <noreply@harmonic.social>", ApplicationMailer.default_from_address
    end
  end

  test "delivered mail carries the display name in its From header" do
    with_env("MAILER_FROM_ADDRESS" => "noreply@example.com", "MAILER_FROM_NAME" => "Harmonic") do
      tenant = create_tenant(subdomain: "mailer-app-#{SecureRandom.hex(4)}", name: "App Mailer")
      host = create_user(email: "apphost-#{SecureRandom.hex(4)}@example.com", name: "App Host")
      tenant.add_user!(host)
      tenant.create_main_collective!(created_by: host)
      identity = OmniAuthIdentity.create!(
        user: host, email: host.email, name: host.name,
        password: "validpassword123", password_confirmation: "validpassword123",
      )
      raw_token = identity.send_email_confirmation!

      email = EmailConfirmationMailer.confirm(identity, raw_token, tenant)

      assert_equal ["noreply@example.com"], email.from
      assert_equal "Harmonic <noreply@example.com>", email[:from].to_s
    end
  end
end
