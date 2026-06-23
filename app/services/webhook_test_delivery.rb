# typed: true

require "ssrf_filter"

# Sends a single synchronous "harmonic.webhook.test" delivery to a webhook URL
# during registration, so that setup fails fast when the runner host is not
# actually reachable. Same wire format as production deliveries (HMAC over
# `<timestamp>.<body>`, sha256 hex digest, `sha256=` prefix), but signed with
# the supplied secret rather than looked up from an AutomationRule.
class WebhookTestDelivery
  extend T::Sig

  EVENT_TYPE = "harmonic.webhook.test".freeze
  TIMEOUT_SECONDS = 10

  Result = Struct.new(:ok, :status, :error, keyword_init: true)

  sig { params(url: String, secret: String).returns(Result) }
  def self.deliver(url:, secret:)
    body = test_payload.to_json
    timestamp = Time.current.to_i
    signature = WebhookDeliveryService.sign(body, timestamp, secret)

    response = SsrfFilter.post(
      url,
      body: body,
      headers: {
        "Content-Type" => "application/json",
        "X-Harmonic-Signature" => "sha256=#{signature}",
        "X-Harmonic-Timestamp" => timestamp.to_s,
        "X-Harmonic-Event" => EVENT_TYPE,
      },
      timeout: TIMEOUT_SECONDS
    )
    status = response.code.to_i
    if status >= 200 && status < 300
      Result.new(ok: true, status: status, error: nil)
    else
      Result.new(ok: false, status: status, error: "HTTP #{status}")
    end
  rescue SsrfFilter::Error => e
    Result.new(ok: false, status: nil, error: "blocked: #{e.message}")
  rescue StandardError => e
    Result.new(ok: false, status: nil, error: e.message)
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def self.test_payload
    {
      "event" => EVENT_TYPE,
      "sent_at" => Time.current.iso8601,
    }
  end
end
