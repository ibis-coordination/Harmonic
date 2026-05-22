# typed: true

# Verifies a Cloudflare Turnstile token by POSTing to the siteverify endpoint.
#
# Disabled-mode: when TURNSTILE_SECRET_KEY is blank, verify? returns true and
# no network call is made. This lets dev/test/CI run without Turnstile credentials
# while keeping production protected.
#
# Fail-closed: any network error, timeout, or malformed response returns false.
# An attacker who can DoS Cloudflare's siteverify must not gain the ability to
# bypass the check — better to surface a transient error to the user.
require "net/http"
require "uri"
require "json"

class TurnstileVerifier
  extend T::Sig

  VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze
  TIMEOUT_SECONDS = 3

  sig { params(token: T.nilable(String), ip: T.nilable(String)).returns(T::Boolean) }
  def self.verify(token:, ip:)
    return true if ENV["TURNSTILE_SECRET_KEY"].to_s.empty?
    return false if token.to_s.empty?

    # URI::HTTPS.build for Sorbet's benefit (URI.parse returns the untyped
    # URI::Generic). Mirrors VERIFY_URL.
    uri = URI::HTTPS.build(host: "challenges.cloudflare.com", path: "/turnstile/v0/siteverify")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT_SECONDS
    http.read_timeout = TIMEOUT_SECONDS

    req = Net::HTTP::Post.new(uri.request_uri)
    req.set_form_data(
      "secret" => ENV.fetch("TURNSTILE_SECRET_KEY", nil),
      "response" => token,
      "remoteip" => ip
    )
    res = http.request(req)
    JSON.parse(res.body).fetch("success", false) == true
  rescue StandardError => e
    Rails.logger.warn("[TurnstileVerifier] verify failed: #{e.class}: #{e.message}")
    false
  end
end
