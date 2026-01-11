# typed: true

require "net/http"
require "openssl"

class WebhookDeliveryService
  extend T::Sig

  MAX_ATTEMPTS = 5
  RETRY_DELAYS = [1.minute, 5.minutes, 30.minutes, 2.hours, 24.hours].freeze
  TIMEOUT_SECONDS = 30

  sig { params(delivery: WebhookDelivery).void }
  def self.deliver!(delivery)
    webhook = delivery.webhook
    return if webhook.nil? || !webhook.enabled?

    timestamp = Time.current.to_i
    body = T.must(delivery.request_body)
    signature = sign(body, timestamp, webhook.secret)

    uri = URI.parse(webhook.url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = TIMEOUT_SECONDS
    http.read_timeout = TIMEOUT_SECONDS

    request = Net::HTTP::Post.new(uri.path.presence || "/")
    request["Content-Type"] = "application/json"
    request["X-Harmonic-Signature"] = "sha256=#{signature}"
    request["X-Harmonic-Timestamp"] = timestamp.to_s
    event = delivery.event
    request["X-Harmonic-Event"] = event&.event_type || "unknown"
    request["X-Harmonic-Delivery"] = delivery.id
    request.body = body

    response = http.request(request)

    if response.code.to_i >= 200 && response.code.to_i < 300
      delivery.update!(
        status: "success",
        response_code: response.code.to_i,
        response_body: response.body.to_s.truncate(1000),
        delivered_at: Time.current,
        attempt_count: delivery.attempt_count + 1,
      )
    else
      handle_failure(delivery, "HTTP #{response.code}: #{response.message}")
    end
  rescue StandardError => e
    handle_failure(delivery, e.message)
  end

  sig { params(delivery: WebhookDelivery, error_message: String).void }
  def self.handle_failure(delivery, error_message)
    attempt = delivery.attempt_count + 1

    if attempt >= MAX_ATTEMPTS
      delivery.update!(
        status: "failed",
        error_message: error_message,
        attempt_count: attempt,
      )
    else
      retry_delay = RETRY_DELAYS[attempt - 1] || RETRY_DELAYS.last
      delivery.update!(
        status: "retrying",
        error_message: error_message,
        attempt_count: attempt,
        next_retry_at: Time.current + T.must(retry_delay),
      )
      WebhookDeliveryJob.set(wait_until: delivery.next_retry_at).perform_later(delivery.id)
    end
  end

  sig { params(body: String, timestamp: Integer, secret: String).returns(String) }
  def self.sign(body, timestamp, secret)
    OpenSSL::HMAC.hexdigest("sha256", secret, "#{timestamp}.#{body}")
  end

  sig { params(body: String, timestamp: String, signature: String, secret: String).returns(T::Boolean) }
  def self.verify_signature(body, timestamp, signature, secret)
    expected = sign(body, timestamp.to_i, secret)
    # Remove "sha256=" prefix if present
    actual = signature.sub(/^sha256=/, "")
    ActiveSupport::SecurityUtils.secure_compare(expected, actual)
  end
end
