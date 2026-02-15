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
    url = delivery.url
    secret = delivery.secret

    return if url.blank? || secret.blank?

    timestamp = Time.current.to_i
    body = T.must(delivery.request_body)
    signature = sign(body, timestamp, secret)

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = TIMEOUT_SECONDS
    http.read_timeout = TIMEOUT_SECONDS

    request = Net::HTTP::Post.new(uri.path.presence || "/")
    request["Content-Type"] = "application/json"
    request["X-Harmonic-Signature"] = "sha256=#{signature}"
    request["X-Harmonic-Timestamp"] = timestamp.to_s
    request["X-Harmonic-Event"] = determine_event_type(delivery)
    request["X-Harmonic-Delivery"] = delivery.id
    request["X-Harmonic-Automation-Run"] = delivery.automation_rule_run_id
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
      # Notify parent run that this delivery completed
      notify_parent_run(delivery)
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
      # Notify parent run that this delivery failed permanently
      notify_parent_run(delivery)
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

  # Notify the parent automation run that this delivery has reached a terminal state.
  # The run will check if all its actions are complete and update its status accordingly.
  sig { params(delivery: WebhookDelivery).void }
  def self.notify_parent_run(delivery)
    run = delivery.automation_rule_run
    return unless run&.running?

    run.update_status_from_actions!
  rescue StandardError => e
    Rails.logger.error("WebhookDeliveryService: Failed to notify parent run: #{e.message}")
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

  # Shared HTTP delivery method for sending webhooks with HMAC signatures.
  # Used by both WebhookDelivery-based webhooks and automation webhook actions.
  #
  # @param url [String] The webhook URL
  # @param body [String] The request body (JSON string)
  # @param secret [String] The secret for HMAC signing
  # @param method [String] HTTP method (POST, PUT, PATCH)
  # @param headers [Hash] Additional headers to include
  # @param timeout [Integer] Request timeout in seconds
  # @return [Hash] Result with :success, :status_code, :body, :error keys
  sig do
    params(
      url: String,
      body: String,
      secret: String,
      method: String,
      headers: T::Hash[String, String],
      timeout: Integer
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.deliver_request(url:, body:, secret:, method: "POST", headers: {}, timeout: TIMEOUT_SECONDS)
    uri = parse_url(url)
    return error_result("Invalid URL: #{url}") unless uri

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = timeout
    http.read_timeout = timeout

    request = build_request(uri, method)
    request.body = body

    # Set content type
    request["Content-Type"] = "application/json"

    # Add HMAC signature headers
    timestamp = Time.current.to_i
    signature = sign(body, timestamp, secret)
    request["X-Harmonic-Signature"] = "sha256=#{signature}"
    request["X-Harmonic-Timestamp"] = timestamp.to_s

    # Add custom headers (after defaults so they can override)
    headers.each do |key, value|
      request[key] = value
    end

    response = http.request(request)

    if response.code.to_i >= 200 && response.code.to_i < 300
      {
        success: true,
        status_code: response.code.to_i,
        body: response.body,
      }
    else
      {
        success: false,
        status_code: response.code.to_i,
        body: response.body,
        error: "HTTP #{response.code}: #{response.message}",
      }
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    error_result("Timeout: #{e.message}")
  rescue Errno::ECONNREFUSED => e
    error_result("Connection refused: #{e.message}")
  rescue SocketError => e
    error_result("Network error: #{e.message}")
  rescue StandardError => e
    error_result(e.message)
  end

  sig { params(url: String).returns(T.nilable(URI::Generic)) }
  def self.parse_url(url)
    uri = URI.parse(url)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    uri
  rescue URI::InvalidURIError
    nil
  end

  ALLOWED_METHODS = %w[POST PUT PATCH].freeze

  sig { params(uri: URI::Generic, method: String).returns(Net::HTTPRequest) }
  def self.build_request(uri, method)
    method = method.upcase
    method = "POST" unless ALLOWED_METHODS.include?(method)

    request_class = case method
                    when "PUT" then Net::HTTP::Put
                    when "PATCH" then Net::HTTP::Patch
                    else Net::HTTP::Post
                    end

    request_class.new(uri.path.presence || "/")
  end

  sig { params(message: String).returns(T::Hash[Symbol, T.untyped]) }
  def self.error_result(message)
    {
      success: false,
      status_code: nil,
      body: nil,
      error: message,
    }
  end

  # Determine the event type for the X-Harmonic-Event header.
  # Uses the event type if available, otherwise falls back to the automation trigger type.
  sig { params(delivery: WebhookDelivery).returns(String) }
  def self.determine_event_type(delivery)
    # If there's an associated event, use its type
    return delivery.event.event_type if delivery.event&.event_type.present?

    # Otherwise, use the automation rule's trigger type (e.g., "manual", "schedule", "webhook")
    run = delivery.automation_rule_run
    trigger_type = run&.automation_rule&.trigger_type
    return "automation.#{trigger_type}" if trigger_type.present?

    "automation"
  end
end
