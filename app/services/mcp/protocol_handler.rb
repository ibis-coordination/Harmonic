# typed: true
# frozen_string_literal: true

module Mcp
  # JSON-RPC 2.0 protocol handler for MCP (Model Context Protocol)
  # See: https://modelcontextprotocol.io and https://www.jsonrpc.org/specification
  class ProtocolHandler
    extend T::Sig

    PROTOCOL_VERSION = "2024-11-05"
    SERVER_NAME = "harmonic"
    SERVER_VERSION = "0.1.0"

    sig { params(user: User, tenant: Tenant, studio: Studio).void }
    def initialize(user:, tenant:, studio:)
      @user = user
      @tenant = tenant
      @studio = studio
      @navigation_state = NavigationState.new
      @initialized = false
    end

    sig { params(request: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[String, T.untyped])) }
    def handle(request)
      method = request["method"]
      id = request["id"]
      params = request["params"] || {}

      result = case method
      when "initialize"
        handle_initialize(params)
      when "initialized"
        # Client acknowledgment, no response needed
        nil
      when "tools/list"
        handle_tools_list
      when "tools/call"
        handle_tool_call(params)
      when "resources/list"
        handle_resources_list
      when "ping"
        {}
      else
        return error_response(id, -32601, "Method not found: #{method}")
      end

      return nil if result.nil?

      {
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => result,
      }
    rescue StandardError => e
      error_response(id, -32603, "Internal error: #{e.message}")
    end

    private

    sig { params(params: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def handle_initialize(params)
      @initialized = true
      {
        "protocolVersion" => PROTOCOL_VERSION,
        "serverInfo" => {
          "name" => SERVER_NAME,
          "version" => SERVER_VERSION,
        },
        "capabilities" => {
          "tools" => {},
          "resources" => {},
        },
      }
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def handle_tools_list
      { "tools" => Tools::DEFINITIONS }
    end

    sig { params(params: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def handle_tool_call(params)
      tool_name = params["name"]
      arguments = params["arguments"] || {}

      case tool_name
      when "navigate"
        execute_navigate(arguments)
      when "execute_action"
        execute_action(arguments)
      else
        { "content" => [{ "type" => "text", "text" => "Unknown tool: #{tool_name}" }], "isError" => true }
      end
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def handle_resources_list
      { "resources" => [] }
    end

    sig { params(arguments: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def execute_navigate(arguments)
      url = arguments["url"]
      return error_content("Missing required parameter: url") if url.nil? || url.empty?

      fetcher = MarkdownFetcher.new(user: @user, tenant: @tenant, studio: @studio)
      result = fetcher.fetch(url)

      if result[:error]
        return error_content(result[:error])
      end

      @navigation_state.navigate(url, result[:actions])

      content = <<~MD
        # Current URL: #{url}

        #{result[:markdown]}

        ## Available Actions

        #{format_actions(result[:actions])}
      MD

      { "content" => [{ "type" => "text", "text" => content }] }
    end

    sig { params(arguments: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def execute_action(arguments)
      action_name = arguments["action"]
      action_params = arguments["params"] || {}

      return error_content("Missing required parameter: action") if action_name.nil? || action_name.empty?

      unless @navigation_state.current_url
        return error_content("No current URL. Call 'navigate' first to go to a page.")
      end

      unless @navigation_state.action_available?(action_name)
        available = @navigation_state.available_actions.map { |a| a[:name] }.join(", ")
        return error_content("Action '#{action_name}' is not available at #{@navigation_state.current_url}. Available actions: #{available}")
      end

      executor = ActionExecutor.new(user: @user, tenant: @tenant, studio: @studio)
      result = executor.execute(
        url: @navigation_state.current_url,
        action: action_name,
        params: action_params,
      )

      if result[:error]
        return error_content(result[:error])
      end

      message = result[:message] || "Action '#{action_name}' completed successfully."
      content = <<~MD
        ✓ #{message}

        Current URL: #{@navigation_state.current_url}

        (Use 'navigate' to see updated content and available actions)
      MD

      { "content" => [{ "type" => "text", "text" => content }] }
    end

    sig { params(actions: T::Array[T::Hash[Symbol, T.untyped]]).returns(String) }
    def format_actions(actions)
      return "No actions available." if actions.empty?

      actions.map do |action|
        desc = "- **#{action[:name]}**: #{action[:description]}"
        if action[:params_string].present? && action[:params_string] != "()"
          desc += "\n  - Parameters: `#{action[:params_string]}`"
        end
        desc
      end.join("\n\n")
    end

    sig { params(message: String).returns(T::Hash[String, T.untyped]) }
    def error_content(message)
      { "content" => [{ "type" => "text", "text" => "Error: #{message}" }], "isError" => true }
    end

    sig { params(id: T.untyped, code: Integer, message: String).returns(T::Hash[String, T.untyped]) }
    def error_response(id, code, message)
      {
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => { "code" => code, "message" => message },
      }
    end
  end
end
