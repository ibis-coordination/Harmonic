# typed: true

require "openssl"
require "ssrf_filter"

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

    # Build headers for the request
    headers = {
      "Content-Type" => "application/json",
      "X-Harmonic-Signature" => "sha256=#{signature}",
      "X-Harmonic-Timestamp" => timestamp.to_s,
      "X-Harmonic-Event" => determine_event_type(delivery),
      "X-Harmonic-Delivery" => delivery.id,
      "X-Harmonic-Automation-Run" => delivery.automation_rule_run_id.to_s,
    }

    # Use ssrf_filter for SSRF-safe HTTP requests
    # This validates the URL after DNS resolution to prevent DNS rebinding attacks
    response = SsrfFilter.post(
      url,
      body: body,
      headers: headers,
      timeout: TIMEOUT_SECONDS
    )

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
  rescue SsrfFilter::Error => e
    # SSRF attempt detected - fail permanently, don't retry
    delivery.update!(
      status: "failed",
      error_message: "Blocked: #{e.message}",
      attempt_count: delivery.attempt_count + 1,
    )
    notify_parent_run(delivery)
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

  # Determine the event type for the X-Harmonic-Event header.
  # Uses the event type if available, otherwise falls back to the automation trigger type.
  sig { params(delivery: WebhookDelivery).returns(String) }
  def self.determine_event_type(delivery)
    # If there's an associated event, use its type
    event = delivery.event
    if event && event.event_type.present?
      return event.event_type
    end

    # Otherwise, use the automation rule's trigger type (e.g., "manual", "schedule", "webhook")
    run = delivery.automation_rule_run
    trigger_type = run&.automation_rule&.trigger_type
    return "automation.#{trigger_type}" if trigger_type.present?

    "automation"
  end
end
