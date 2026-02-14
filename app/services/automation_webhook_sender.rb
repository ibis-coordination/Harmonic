# typed: true
# frozen_string_literal: true

# AutomationWebhookSender sends HTTP webhooks for automation rules.
# Uses WebhookDeliveryService for HTTP delivery with HMAC signatures.
#
# It supports:
# - POST/PUT/PATCH requests to arbitrary URLs
# - Template variable rendering in body content
# - Custom headers (including authentication)
# - Timeout configuration
# - HMAC signature headers for security
# - Error handling with detailed results
#
# Example action:
#   {
#     "type" => "webhook",
#     "url" => "https://hooks.slack.com/...",
#     "method" => "POST",  # optional, defaults to POST
#     "body" => { "text" => "Event: {{event.type}}" },
#     "headers" => { "Authorization" => "Bearer ..." },  # optional
#     "timeout" => 30  # optional, defaults to 30 seconds
#   }
class AutomationWebhookSender
  extend T::Sig

  DEFAULT_TIMEOUT = 30 # seconds

  # Send a webhook based on the action configuration.
  #
  # @param action [Hash] The webhook action configuration
  # @param event [Event, nil] The triggering event (for template rendering)
  # @param secret [String] The secret for HMAC signing
  # @return [Hash] Result hash with :success, :status_code, :body, :error keys
  sig do
    params(
      action: T::Hash[String, T.untyped],
      event: T.nilable(Event),
      secret: String
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.call(action, event, secret:)
    new(action, event, secret).send_webhook
  end

  sig { params(action: T::Hash[String, T.untyped], event: T.nilable(Event), secret: String).void }
  def initialize(action, event, secret)
    @action = action
    @event = event
    @secret = secret
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def send_webhook
    # Validate URL
    url_string = @action["url"]
    return error_result("URL is required for webhook action") if url_string.blank?

    # Build rendered body
    body = render_body(@action["body"] || {})
    body_json = body.to_json

    # Get custom headers
    headers = build_headers

    # Get HTTP method and timeout
    method = (@action["method"] || "POST").upcase
    timeout = (@action["timeout"] || DEFAULT_TIMEOUT).to_i

    # Delegate to WebhookDeliveryService for HTTP delivery with HMAC signing
    WebhookDeliveryService.deliver_request(
      url: url_string,
      body: body_json,
      secret: @secret,
      method: method,
      headers: headers,
      timeout: timeout
    )
  rescue StandardError => e
    error_result(e.message)
  end

  private

  sig { returns(T::Hash[String, String]) }
  def build_headers
    headers = {}
    custom_headers = @action["headers"]
    if custom_headers.is_a?(Hash)
      custom_headers.each do |key, value|
        headers[key.to_s] = value.to_s
      end
    end
    headers
  end

  sig { params(body: T.untyped).returns(T.untyped) }
  def render_body(body)
    case body
    when Hash
      body.transform_values { |v| render_body(v) }
    when Array
      body.map { |v| render_body(v) }
    when String
      render_template(body)
    else
      body
    end
  end

  sig { params(template: String).returns(String) }
  def render_template(template)
    return template unless @event

    context = AutomationTemplateRenderer.context_from_event(@event)
    AutomationTemplateRenderer.render(template, context)
  end

  sig { params(message: String).returns(T::Hash[Symbol, T.untyped]) }
  def error_result(message)
    {
      success: false,
      status_code: nil,
      body: nil,
      error: message,
    }
  end
end
