# typed: true
# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# AutomationWebhookSender sends HTTP webhooks for automation rules.
#
# It supports:
# - POST/PUT/PATCH requests to arbitrary URLs
# - Template variable rendering in body content
# - Custom headers (including authentication)
# - Timeout configuration
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
  ALLOWED_METHODS = ["POST", "PUT", "PATCH"].freeze

  # Send a webhook based on the action configuration.
  #
  # @param action [Hash] The webhook action configuration
  # @param event [Event, nil] The triggering event (for template rendering)
  # @return [Hash] Result hash with :success, :status_code, :body, :error keys
  sig { params(action: T::Hash[String, T.untyped], event: T.nilable(Event)).returns(T::Hash[Symbol, T.untyped]) }
  def self.call(action, event)
    new(action, event).send_webhook
  end

  sig { params(action: T::Hash[String, T.untyped], event: T.nilable(Event)).void }
  def initialize(action, event)
    @action = action
    @event = event
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def send_webhook
    # Validate URL
    url_string = @action["url"]
    return error_result("URL is required for webhook action") if url_string.blank?

    uri = parse_url(url_string)
    return error_result("Invalid URL: #{url_string}") unless uri

    # Build request
    request = build_request(uri)

    # Send request
    execute_request(uri, request)
  rescue StandardError => e
    error_result(e.message)
  end

  private

  sig { params(url_string: String).returns(T.nilable(URI::HTTP)) }
  def parse_url(url_string)
    uri = URI.parse(url_string)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    uri
  rescue URI::InvalidURIError
    nil
  end

  sig { params(uri: URI::HTTP).returns(Net::HTTPRequest) }
  def build_request(uri)
    method = (@action["method"] || "POST").upcase
    method = "POST" unless ALLOWED_METHODS.include?(method)

    request_class = case method
                    when "PUT" then Net::HTTP::Put
                    when "PATCH" then Net::HTTP::Patch
                    else Net::HTTP::Post
                    end

    request = request_class.new(uri)

    # Set content type
    request["Content-Type"] = "application/json"

    # Set custom headers
    headers = @action["headers"]
    if headers.is_a?(Hash)
      headers.each do |key, value|
        request[key.to_s] = value.to_s
      end
    end

    # Build and set body
    body = render_body(@action["body"] || {})
    request.body = body.to_json

    request
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

  sig { params(uri: URI::HTTP, request: Net::HTTPRequest).returns(T::Hash[Symbol, T.untyped]) }
  def execute_request(uri, request)
    timeout = (@action["timeout"] || DEFAULT_TIMEOUT).to_i

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = timeout
    http.read_timeout = timeout

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      success_result(response)
    else
      failure_result(response)
    end
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    error_result("Timeout: #{e.message}")
  rescue Errno::ECONNREFUSED => e
    error_result("Connection refused: #{e.message}")
  rescue SocketError => e
    error_result("Network error: #{e.message}")
  end

  sig { params(response: Net::HTTPResponse).returns(T::Hash[Symbol, T.untyped]) }
  def success_result(response)
    {
      success: true,
      status_code: response.code.to_i,
      body: response.body,
    }
  end

  sig { params(response: Net::HTTPResponse).returns(T::Hash[Symbol, T.untyped]) }
  def failure_result(response)
    {
      success: false,
      status_code: response.code.to_i,
      body: response.body,
      error: "HTTP #{response.code}: #{response.message}",
    }
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
