# typed: true
# frozen_string_literal: true

require "net/http"
require "uri"

module Mcp
  # Fetches markdown content and available actions for a given URL
  # Makes HTTP requests to the Rails app with Accept: text/markdown
  class MarkdownFetcher
    extend T::Sig

    sig { params(user: User, tenant: Tenant, studio: Studio, api_token: T.nilable(String), base_url: T.nilable(String)).void }
    def initialize(user:, tenant:, studio:, api_token: nil, base_url: nil)
      @user = user
      @tenant = tenant
      @studio = studio
      @api_token = api_token || ENV["HARMONIC_API_TOKEN"]
      @base_url = base_url || ENV["HARMONIC_BASE_URL"] || "http://#{tenant.subdomain}.localhost:3000"
    end

    sig { params(url: String).returns(T::Hash[Symbol, T.untyped]) }
    def fetch(url)
      # Normalize URL - ensure it starts with /
      url = "/#{url}" unless url.start_with?("/")

      full_url = "#{@base_url}#{url}"
      uri = T.cast(URI.parse(full_url), URI::HTTP)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Get.new(T.must(uri.request_uri))
      request["Accept"] = "text/markdown"
      request["Authorization"] = "Bearer #{@api_token}" if @api_token

      response = http.request(request)

      case response.code.to_i
      when 200
        markdown = response.body
        actions = extract_actions_from_url(url)
        { markdown: markdown, actions: actions }
      when 401
        { error: "Unauthorized. Check your API token.", markdown: nil, actions: [] }
      when 403
        { error: "Forbidden. You don't have access to this resource.", markdown: nil, actions: [] }
      when 404
        { error: "Not found: #{url}", markdown: nil, actions: [] }
      else
        { error: "HTTP #{response.code}: #{response.message}", markdown: nil, actions: [] }
      end
    rescue StandardError => e
      { error: "Failed to fetch #{url}: #{e.message}", markdown: nil, actions: [] }
    end

    private

    # Extract actions based on the URL pattern using ActionsHelper
    sig { params(url: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def extract_actions_from_url(url)
      # Convert actual URL to route pattern for ActionsHelper lookup
      route_pattern = url_to_route_pattern(url)
      actions_data = ActionsHelper.actions_for_route(route_pattern)
      actions_data ? actions_data[:actions] : []
    end

    # Convert a concrete URL like /studios/team/n/abc123 to a pattern like /studios/:studio_handle/n/:note_id
    sig { params(url: String).returns(String) }
    def url_to_route_pattern(url)
      # Remove query string if present
      url = url.split("?").first || url

      # Common patterns to match
      patterns = [
        # Note routes
        [%r{^/studios/[^/]+/n/[^/]+/edit$}, "/studios/:studio_handle/n/:note_id/edit"],
        [%r{^/studios/[^/]+/n/[^/]+$}, "/studios/:studio_handle/n/:note_id"],
        [%r{^/studios/[^/]+/note$}, "/studios/:studio_handle/note"],

        # Decision routes
        [%r{^/studios/[^/]+/d/[^/]+/settings$}, "/studios/:studio_handle/d/:decision_id/settings"],
        [%r{^/studios/[^/]+/d/[^/]+$}, "/studios/:studio_handle/d/:decision_id"],
        [%r{^/studios/[^/]+/decide$}, "/studios/:studio_handle/decide"],

        # Commitment routes
        [%r{^/studios/[^/]+/c/[^/]+/settings$}, "/studios/:studio_handle/c/:commitment_id/settings"],
        [%r{^/studios/[^/]+/c/[^/]+$}, "/studios/:studio_handle/c/:commitment_id"],
        [%r{^/studios/[^/]+/commit$}, "/studios/:studio_handle/commit"],

        # Studio routes
        [%r{^/studios/[^/]+/join$}, "/studios/:studio_handle/join"],
        [%r{^/studios/[^/]+/settings$}, "/studios/:studio_handle/settings"],
        [%r{^/studios/[^/]+/cycles$}, "/studios/:studio_handle/cycles"],
        [%r{^/studios/[^/]+/backlinks$}, "/studios/:studio_handle/backlinks"],
        [%r{^/studios/[^/]+/team$}, "/studios/:studio_handle/team"],
        [%r{^/studios/[^/]+$}, "/studios/:studio_handle"],
        [%r{^/studios/new$}, "/studios/new"],
        [%r{^/studios$}, "/studios"],
      ]

      patterns.each do |regex, pattern|
        return pattern if url.match?(regex)
      end

      # Return original URL if no pattern matches
      url
    end
  end
end
