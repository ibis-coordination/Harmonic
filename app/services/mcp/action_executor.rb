# typed: true
# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Mcp
  # Executes contextual actions by making HTTP POST requests to the Rails app
  class ActionExecutor
    extend T::Sig

    sig { params(user: User, tenant: Tenant, studio: Studio, api_token: T.nilable(String), base_url: T.nilable(String)).void }
    def initialize(user:, tenant:, studio:, api_token: nil, base_url: nil)
      @user = user
      @tenant = tenant
      @studio = studio
      @api_token = api_token || ENV["HARMONIC_API_TOKEN"]
      @base_url = base_url || ENV["HARMONIC_BASE_URL"] || "http://#{tenant.subdomain}.localhost:3000"
    end

    sig { params(url: String, action: String, params: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def execute(url:, action:, params:)
      # Build the action URL: {current_url}/actions/{action_name}
      # Handle URLs that might already have /edit or other suffixes
      action_url = build_action_url(url, action)

      full_url = "#{@base_url}#{action_url}"
      uri = T.cast(URI.parse(full_url), URI::HTTP)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Post.new(T.must(uri.request_uri))
      request["Accept"] = "text/markdown"
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@api_token}" if @api_token
      request.body = params.to_json

      response = http.request(request)

      case response.code.to_i
      when 200, 201
        { success: true, message: extract_success_message(response.body, action), body: response.body }
      when 302, 303
        # Redirect indicates success, follow it or report success
        { success: true, message: "#{action.humanize} completed successfully.", redirect_to: response["Location"] }
      when 400
        { error: "Bad request: #{extract_error_message(response.body)}" }
      when 401
        { error: "Unauthorized. Check your API token." }
      when 403
        { error: "Forbidden. You don't have permission to perform this action." }
      when 404
        { error: "Action not found: #{action}" }
      when 422
        { error: "Validation error: #{extract_error_message(response.body)}" }
      else
        { error: "HTTP #{response.code}: #{response.message}" }
      end
    rescue StandardError => e
      { error: "Failed to execute #{action}: #{e.message}" }
    end

    private

    sig { params(url: String, action: String).returns(String) }
    def build_action_url(url, action)
      # Remove trailing slash
      url = url.chomp("/")

      # The action URL pattern is {base_url}/actions/{action_name}
      "#{url}/actions/#{action}"
    end

    sig { params(body: String, action: String).returns(String) }
    def extract_success_message(body, action)
      # Try to extract a meaningful message from the response
      # The markdown response might contain a success message
      if body.include?("Success") || body.include?("success")
        # Try to find a success line
        lines = body.lines
        success_line = lines.find { |l| l.downcase.include?("success") }
        return success_line.strip if success_line
      end

      # Default message
      "#{action.humanize} completed successfully."
    end

    sig { params(body: String).returns(String) }
    def extract_error_message(body)
      # Try to parse as JSON for error details
      begin
        json = JSON.parse(body)
        return json["error"] if json["error"]
        return json["errors"].join(", ") if json["errors"].is_a?(Array)
        return json["message"] if json["message"]
      rescue JSON::ParserError
        # Not JSON, try to extract from markdown/text
      end

      # Try to find error in markdown
      if body.include?("Error") || body.include?("error")
        lines = body.lines
        error_line = lines.find { |l| l.downcase.include?("error") }
        return error_line.strip if error_line
      end

      # Return truncated body as fallback
      body.length > 200 ? "#{body[0..200]}..." : body
    end
  end
end
