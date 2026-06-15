# typed: false
# frozen_string_literal: true

# MCP (Model Context Protocol) Streamable HTTP endpoint.
#
# Speaks the JSON-RPC 2.0 envelope for the 2025-11-25 revision of the
# Streamable HTTP transport. External MCP clients (Claude Desktop, Claude
# Code, Codex, Cursor, etc.) POST JSON-RPC messages here authenticated by their
# Bearer token. Exposes four tools — fetch_page, execute_action, search,
# get_help — and one resource, harmonic://context. Tool calls delegate to
# the existing markdown-rendering controllers via internal dispatch
# through MarkdownUiService.
#
# Inherits from ActionController::Base (not ApplicationController) for the
# same reason as Internal::BaseController: ApplicationController's filter
# chain assumes browser sessions, collective-scoped routes, and a
# resource-model heuristic — none of which apply to a JSON-RPC endpoint.
#
# Security model
# --------------
# The Bearer check here is DEFENSE IN DEPTH, not the authoritative gate. Every
# tool call dispatches through MarkdownUiService, which makes a real internal
# HTTP request through ActionDispatch::Integration::Session with the caller's
# Bearer token. That inner request hits ApplicationController's full filter
# chain — api_authorize! (tenant.api_enabled?, collective.api_enabled?,
# billing, activation) and ActionCapabilityCheck (per-action capability gate).
# So MCP doesn't grant any new privileges — every check the same Bearer
# would face on direct HTTPS still fires here (with one extra restriction:
# the agent-identity gate). The endpoint-level checks below exist to
# (a) return MCP-shaped errors before we ever touch the inner dispatch,
# and (b) produce the spec-mandated WWW-Authenticate header.
#
# This contract is pinned by the "Inner-dispatch security" tests in the
# endpoint controller test file — they intentionally disable tenant/collective
# API at the model layer and assert that tool calls surface the rejection.
# If you find yourself moving auth logic out of the inner controllers into
# this one, you are wrong; the test will catch it.
#
# Audit log lifecycle
# -------------------
# The McpToolCallLog row is created BEFORE the inner dispatch (with
# status: "pending") so its id is available via Current.mcp_tool_call_log_id
# to deeper code that needs to FK against the call — primarily
# track_task_run_resource for per-call resource attribution. After
# dispatch returns, the row is updated to its final status (ok, tool_error,
# or unknown_tool) plus duration_ms. If the dispatch raises, the row
# stays "pending" forever — an operator signal that the process was
# killed mid-dispatch. Current.mcp_tool_call_log_id resets automatically
# between requests via ActionDispatch::Executor.
#
# Spec: https://modelcontextprotocol.io/specification/2025-11-25
module Mcp
  # rubocop:disable Rails/ApplicationController
  class EndpointController < ActionController::Base
    # rubocop:enable Rails/ApplicationController
    include RateLimits

    SUPPORTED_PROTOCOL_VERSIONS = ["2025-11-25"].freeze
    SERVER_VERSION = "0.1.0"

    # Rate-limit thresholds. Class methods so tests can stub them down.
    def self.burst_limit_per_token = 10            # per token / second
    def self.sustained_limit_per_token = 60        # per token / minute
    def self.sustained_limit_per_principal = 600   # per principal / minute (caps cumulative throughput across one human's agents)
    def self.aggregate_limit_per_tenant = 6_000    # per tenant / minute (default; tunable via Tenant#mcp_aggregate_rate_limit_per_minute)
    def self.max_request_bytes = 262_144           # 256 KiB cap on /mcp request body
    def self.max_response_bytes = 1_048_576        # 1 MiB cap on tool-result text

    # JSON-RPC 2.0 error codes (https://www.jsonrpc.org/specification#error_object)
    PARSE_ERROR = -32_700
    INVALID_REQUEST = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS = -32_602
    INTERNAL_ERROR = -32_603

    # ====================
    # Tool descriptors
    # ====================

    FETCH_PAGE_TOOL = {
      name: "fetch_page",
      description:
        "Fetch the markdown representation of a Harmonic page at the given path. " \
        "The response includes content plus a list of actions available at that path, " \
        "each with a fully-qualified action URL you can pass back to execute_action. " \
        "Examples: '/collectives/team', '/collectives/team/d/abc123', '/collectives/team/cycles/today'",
      inputSchema: {
        type: "object",
        required: ["path"],
        properties: {
          path: { type: "string", description: "Relative path (e.g., '/collectives/team/n/abc123')" },
        },
      },
      annotations: { readOnlyHint: true },
    }.freeze

    EXECUTE_ACTION_TOOL = {
      name: "execute_action",
      description:
        "Execute an action at a given Harmonic page. " \
        "Pass the path of the page (e.g. '/collectives/team/n/abc123'), the action name " \
        "(from the page's action list, e.g. 'add_comment'), and any params the action requires.",
      inputSchema: {
        type: "object",
        required: ["path", "action"],
        properties: {
          path: { type: "string", description: "Path of the page the action operates on (e.g., '/collectives/team/n/abc123')." },
          action: { type: "string", description: "Action name (from the action list on the page)." },
          params: {
            type: "object",
            additionalProperties: true,
            description: "Parameters for the action (see the action's parameter list).",
          },
        },
      },
      annotations: { destructiveHint: true },
    }.freeze

    SEARCH_TOOL = {
      name: "search",
      description:
        "Search Harmonic for notes, decisions, commitments, and people. " \
        "Supports filter, sort, and group operators (e.g. type:, collective:, " \
        "creator:@handle, status:). For the full operator reference, fetch " \
        "/help/search.",
      inputSchema: {
        type: "object",
        required: ["query"],
        properties: {
          query: { type: "string", description: "Search query." },
        },
      },
      annotations: { readOnlyHint: true },
    }.freeze

    GET_HELP_TOOL = {
      name: "get_help",
      description:
        "Read Harmonic documentation. Pass a topic name (e.g. 'notes', 'decisions', " \
        "'reminder-notes') to read that topic, or call with no arguments to get the " \
        "index of available topics.",
      inputSchema: {
        type: "object",
        properties: {
          topic: {
            type: "string",
            description: "Topic name (e.g. 'notes', 'reminder-notes', 'search'). Omit to get the index.",
          },
        },
      },
      annotations: { readOnlyHint: true },
    }.freeze

    TOOL_DESCRIPTORS = [FETCH_PAGE_TOOL, EXECUTE_ACTION_TOOL, SEARCH_TOOL, GET_HELP_TOOL].freeze

    KNOWN_TOOL_NAMES = TOOL_DESCRIPTORS.pluck(:name).freeze

    # Per-tool allowlist of argument field names, derived from each
    # descriptor's inputSchema. Used by the audit logger to strip undeclared
    # fields the agent may have included in `arguments` — only fields the
    # tool actually consumes can land in the log. Keeping this derived from
    # TOOL_DESCRIPTORS ensures it stays in sync as schemas evolve.
    TOOL_ARG_FIELDS = TOOL_DESCRIPTORS.to_h do |d|
      [d[:name], d.dig(:inputSchema, :properties).keys.map(&:to_s)]
    end.freeze

    # ====================
    # Resource descriptors
    # ====================

    CONTEXT_RESOURCE_URI = "harmonic://context"

    CONTEXT_RESOURCE_TEXT = <<~MD
      # Harmonic MCP Context

      Harmonic is a social coordination platform for sharing notes,
      making decisions together, and coordinating action.

      ## Tools

      - `fetch_page(path)` — Read a page. Returns markdown content with
        YAML frontmatter listing the actions available at that path, each
        with its param schema. Start at `/whoami` to see your identity
        and what's available.
      - `execute_action(path, action, params)` — Invoke an action. Use
        action names from the page's frontmatter; the required params are
        listed there.
      - `search(query)` — Search across notes, decisions, commitments,
        and people. Supports filter, sort, and group operators — fetch
        `/help/search` for the operator reference.
      - `get_help(topic)` — Read Harmonic documentation. Call with no
        arguments to see the index of available topics.

      ## Getting started

      Start at `/whoami` to see your identity, your persistent memory
      (scratchpad and private workspace), and the collectives you belong
      to. From a collective's page you can see its notes, decisions, and
      commitments — and the actions available to you.
    MD

    CONTEXT_RESOURCE_DESCRIPTOR = {
      uri: CONTEXT_RESOURCE_URI,
      name: "Harmonic context",
      description: "Documentation and context for using Harmonic — what the tools do and how to get started.",
      mimeType: "text/markdown",
    }.freeze

    RESOURCE_DESCRIPTORS = [CONTEXT_RESOURCE_DESCRIPTOR].freeze

    # No browser session, no CSRF.
    skip_forgery_protection

    # Catch any unhandled exception and return a JSON-RPC error envelope.
    # Without this, ActionController::Base falls back to Rails' default HTML
    # error page — useless for an MCP client expecting JSON.
    rescue_from StandardError, with: :render_internal_error

    before_action :resolve_mcp_tenant!
    before_action :reject_invalid_origin!
    before_action :reject_invalid_accept!
    before_action :reject_unsupported_protocol_version!
    before_action :authenticate_mcp_bearer!
    before_action :enforce_mcp_rate_limits!

    def handle
      raw = request.raw_post
      return render_payload_too_large if raw.bytesize > self.class.max_request_bytes

      body = parse_body(raw)

      return render_parse_error if body.nil?
      return render_batch_unsupported if body.is_a?(Array)
      return render_invalid_request("Request body must be a JSON object") unless body.is_a?(Hash)

      response = dispatch_method(body)
      if response == :accepted
        head :accepted
      else
        render json: response
      end
    end

    private

    # ====================
    # Filters
    # ====================

    def resolve_mcp_tenant!
      @current_tenant = Tenant.find_by(subdomain: request.subdomain)
      return head :not_found unless @current_tenant

      Tenant.scope_thread_to_tenant(subdomain: @current_tenant.subdomain)
    end

    attr_reader :current_tenant

    def reject_invalid_origin!
      origin = request.headers["Origin"]
      return if origin.blank? # Desktop MCP clients send no Origin; that's allowed.

      allowed = ["https://#{request.host}", "http://#{request.host}"]
      return if allowed.include?(origin)

      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST, "Invalid Origin"), status: :forbidden
    end

    # The Streamable HTTP spec says clients MUST include both application/json
    # and text/event-stream in their Accept header. We only ever respond with
    # application/json (no SSE streams in this implementation), so we accept
    # anything that doesn't explicitly exclude JSON — missing Accept (implicit
    # */*) is fine, and so is application/json on its own.
    def reject_invalid_accept!
      accept = request.headers["Accept"].to_s
      return if accept.empty?
      return if accept.include?("application/json") || accept.include?("*/*")

      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST, "Accept header must include application/json"),
             status: :not_acceptable
    end

    def reject_unsupported_protocol_version!
      version = request.headers["MCP-Protocol-Version"]
      return if version.blank?
      return if SUPPORTED_PROTOCOL_VERSIONS.include?(version)

      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST, "Unsupported MCP-Protocol-Version: #{version}"),
             status: :bad_request
    end

    def authenticate_mcp_bearer!
      auth_header = request.headers["Authorization"].to_s
      return render_mcp_unauthorized if auth_header.blank?

      prefix, plaintext = auth_header.split(" ", 2)
      # RFC 7235: auth-scheme is case-insensitive.
      return render_mcp_unauthorized unless prefix.to_s.downcase == "bearer" && plaintext.present?

      token = ApiToken.authenticate(plaintext, tenant_id: current_tenant.id)
      return render_mcp_unauthorized unless token&.active?

      # MCP connections must act as an AI agent identity, not as a human
      # user. The MCP client is an LLM, and letting an LLM authenticate as a
      # human would record its activity under the human's name — a social-
      # agency violation. See /help/mcp for the full explanation.
      return render_mcp_non_agent_forbidden(token.user) unless token.user.ai_agent?

      token.token_used!
      @current_token = token
      @plaintext_bearer = plaintext
    end

    # 429 with Retry-After when any of: per-token burst, per-token sustained,
    # per-principal sustained, or per-tenant aggregate is exceeded. Logs to
    # SecurityAuditLog so operators can detect abusive agents, principals,
    # or tenants without parsing general request logs.
    def enforce_mcp_rate_limits!
      enforce_rate_limit!(scope: "mcp/burst", key: @current_token.id,
                          limit: self.class.burst_limit_per_token, period: 1.second)
      enforce_rate_limit!(scope: "mcp/sustained", key: @current_token.id,
                          limit: self.class.sustained_limit_per_token, period: 1.minute)
      enforce_rate_limit!(scope: "mcp/principal", key: @current_token.user.principal_id,
                          limit: self.class.sustained_limit_per_principal, period: 1.minute)
      enforce_rate_limit!(scope: "mcp/tenant", key: current_tenant.id,
                          limit: tenant_aggregate_limit, period: 1.minute)
    rescue RateLimits::Exceeded => e
      SecurityAuditLog.log_mcp_rate_limited(
        scope: e.scope,
        tenant_id: current_tenant.id,
        token_id: @current_token.id,
        user_id: @current_token.user_id,
        principal_id: @current_token.user.principal_id,
        ip: request.remote_ip,
        request_id: request.request_id
      )
      retry_after = e.period.to_i
      response.set_header("Retry-After", retry_after.to_s)
      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST,
                                          "Rate limit exceeded (#{e.scope}). Retry after #{retry_after}s."),
             status: :too_many_requests
    end

    # Tenant override (set via Tenant#mcp_aggregate_rate_limit_per_minute) wins
    # over the class default. Lets us raise the cap on a public tenant with
    # enough paying principals to outgrow 6,000/min.
    def tenant_aggregate_limit
      current_tenant.mcp_aggregate_rate_limit_per_minute || self.class.aggregate_limit_per_tenant
    end

    def render_mcp_unauthorized
      response.set_header(
        "WWW-Authenticate",
        %(Bearer realm="Harmonic", resource_metadata="#{resource_metadata_url}")
      )
      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST, "Unauthorized"), status: :unauthorized
    end

    def render_mcp_non_agent_forbidden(user)
      message = "MCP requires an AI agent identity. The token you supplied belongs to a #{user.user_type} user @#{user.handle}. " \
                "Create an agent at /ai-agents/new and use its token instead. See /help/mcp for details."
      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST, message), status: :forbidden
    end

    def resource_metadata_url
      # The MCP spec's WWW-Authenticate scheme requires advertising this URL
      # so clients can discover the OAuth Protected Resource Metadata document
      # (RFC 9728) once that endpoint is served at this location.
      "https://#{request.host}/.well-known/oauth-protected-resource"
    end

    # ====================
    # Request parsing
    # ====================

    def parse_body(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def render_parse_error
      render json: jsonrpc_error_envelope(nil, PARSE_ERROR, "Parse error")
    end

    def render_payload_too_large
      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST,
                                          "Request body exceeds #{self.class.max_request_bytes} bytes"),
             status: :payload_too_large
    end

    def render_batch_unsupported
      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST, "JSON-RPC batches are not supported"),
             status: :bad_request
    end

    def render_invalid_request(message)
      render json: jsonrpc_error_envelope(nil, INVALID_REQUEST, message), status: :bad_request
    end

    def render_internal_error(error)
      Rails.logger.error("[Mcp::EndpointController] #{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}")
      render json: jsonrpc_error_envelope(nil, INTERNAL_ERROR, "Internal error"), status: :internal_server_error
    end

    # ====================
    # JSON-RPC dispatch
    # ====================

    def dispatch_method(body)
      # Per JSON-RPC 2.0: a message without an `id` field is a notification.
      # Method name (including "notifications/*" by MCP convention) is
      # informational; absence of `id` is what makes it a notification, and
      # the server MUST NOT respond. We ack with 202.
      return :accepted unless body.key?("id")

      id = body["id"]
      method = body["method"].to_s
      params = body["params"] || {}

      case method
      when "initialize"
        handle_initialize(id, params)
      when "ping"
        jsonrpc_result(id, {})
      when "tools/list"
        jsonrpc_result(id, { tools: TOOL_DESCRIPTORS })
      when "tools/call"
        handle_tools_call(id, params)
      when "resources/list"
        jsonrpc_result(id, { resources: RESOURCE_DESCRIPTORS })
      when "resources/read"
        handle_resources_read(id, params)
      else
        jsonrpc_error_envelope(id, METHOD_NOT_FOUND, "Method not found: #{method}")
      end
    end

    def handle_initialize(id, _params)
      jsonrpc_result(id, {
                       protocolVersion: SUPPORTED_PROTOCOL_VERSIONS.first,
                       serverInfo: { name: "harmonic", version: SERVER_VERSION },
                       # Advertise only the capabilities we actually implement —
                       # no prompts, logging, or sampling.
                       capabilities: { tools: {}, resources: {} },
                     })
    end

    # ====================
    # Resources
    # ====================

    def handle_resources_read(id, params)
      return jsonrpc_error_envelope(id, INVALID_PARAMS, "params must be an object") unless params.is_a?(Hash)

      uri = params["uri"].to_s
      return jsonrpc_error_envelope(id, INVALID_PARAMS, "Missing required argument: uri") if uri.empty?

      case uri
      when CONTEXT_RESOURCE_URI
        jsonrpc_result(id, {
                         contents: [
                           {
                             uri: CONTEXT_RESOURCE_URI,
                             mimeType: "text/markdown",
                             text: CONTEXT_RESOURCE_TEXT,
                           },
                         ],
                       })
      else
        jsonrpc_error_envelope(id, INVALID_PARAMS, "Unknown resource: #{uri}")
      end
    end

    # ====================
    # Tools
    # ====================

    def handle_tools_call(id, params)
      return jsonrpc_error_envelope(id, INVALID_PARAMS, "params must be an object") unless params.is_a?(Hash)
      return jsonrpc_error_envelope(id, INVALID_PARAMS, "Missing required argument: name") if params["name"].blank?

      name = params["name"].to_s
      args = params["arguments"]
      args = {} unless args.is_a?(Hash)

      # Create the log row before dispatch so its id is available via
      # Current.mcp_tool_call_log_id to deeper code that needs to FK
      # against the call (notably track_task_run_resource for resource
      # attribution). Row stays `pending` and Current stays set if the
      # dispatch raises — operators can detect orphaned `pending` rows
      # as a "process killed mid-dispatch" signal; Current resets when
      # Rails clears request-scoped state.
      log = McpToolCallLog.create!(
        tenant: current_tenant,
        user: @current_token.user,
        api_token: @current_token,
        tool_name: name,
        arguments: redact_args_for_log(name, args),
        status: "pending",
        duration_ms: 0,
        request_id: request.request_id
      )
      Current.mcp_tool_call_log_id = log.id

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      envelope = case name
                 when "fetch_page" then call_fetch_page(id, args)
                 when "execute_action" then call_execute_action(id, args)
                 when "search" then call_search(id, args)
                 when "get_help" then call_get_help(id, args)
                 else tool_error_result(id, "Unknown tool: #{name}")
                 end
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      log.update!(status: tool_call_status(name, envelope), duration_ms: duration_ms)
      envelope
    end

    def tool_call_status(name, envelope)
      if KNOWN_TOOL_NAMES.exclude?(name)
        "unknown_tool"
      elsif envelope.dig(:result, :isError)
        "tool_error"
      else
        "ok"
      end
    end

    # Build the redacted args payload to persist on an audit row.
    #
    # First, slice to the fields declared in the tool's inputSchema — any
    # undeclared key the agent included in `arguments` is dropped. This
    # prevents leakage from extras like `fetch_page` being called with a
    # bogus `params: "<secret>"` field that the tool never consumes but a
    # naive logger would persist. Unknown tools have no allowlist, so
    # their args are reduced to `{}` — the principal still sees the tool
    # name and status, but no agent-controlled payload lands in the log.
    #
    # Second, for execute_action, replace the `params` value with a shape
    # summary regardless of its type (`{keys: [...]}` for a Hash,
    # `{type: "..."}` for malformed, `nil` for absent). execute_action is
    # the only tool whose declared arg can carry free-form user content
    # (note body, comment text, etc.); the principal can see WHICH fields
    # the agent set without seeing the content, and the content itself is
    # retrievable via the resulting record.
    #
    # Other tools' declared arguments are intent fields (paths, queries,
    # topic names) and are logged verbatim — dropping them would defeat
    # the purpose of the audit log.
    def redact_args_for_log(name, args)
      allowed = TOOL_ARG_FIELDS[name]
      return {} if allowed.nil?

      filtered = args.slice(*allowed)
      return filtered unless name == "execute_action"

      summary = case (raw = filtered["params"])
                when Hash then { "keys" => raw.keys }
                when nil then nil
                else { "type" => raw.class.name }
                end
      filtered.merge("params" => summary)
    end

    def call_fetch_page(id, args)
      path = args["path"]
      return tool_error_result(id, "Missing required argument: path") if path.blank?
      return tool_error_result(id, invalid_path_message) unless valid_relative_path?(path)

      navigate_and_surface(id, path)
    end

    def call_execute_action(id, args)
      path = args["path"]
      action_name = args["action"]
      raw_params = args["params"]
      action_params = raw_params.nil? ? {} : raw_params

      return tool_error_result(id, "Missing required argument: path") if path.blank?
      return tool_error_result(id, "Missing required argument: action") if action_name.blank?
      return tool_error_result(id, "action must be a string") unless action_name.is_a?(String)
      return tool_error_result(id, "params must be an object") unless action_params.is_a?(Hash)
      return tool_error_result(id, invalid_path_message) unless valid_relative_path?(path)

      normalized = normalize_action_path(path)
      return tool_error_result(id, invalid_path_message) if normalized.empty?

      # Stash the action name on Current so track_task_run_resource (which fires
      # deep inside the dispatched action controller) can attribute touched
      # resources to this specific MCP call with the correct action_name.
      Current.mcp_action_name = action_name

      service = MarkdownUiService.new(tenant: current_tenant, user: @current_token.user)
      result = service.with_provided_token(@plaintext_bearer) do
        service.set_path(normalized)
        service.execute_action(action_name, action_params)
      end
      surface_dispatch_result(id, result)
    end

    def call_search(id, args)
      query = args["query"]
      return tool_error_result(id, "Missing required argument: query") if query.blank?
      return tool_error_result(id, "query must be a string") unless query.is_a?(String)

      navigate_and_surface(id, "/search?q=#{CGI.escape(query)}")
    end

    def call_get_help(id, args)
      topic = args["topic"]
      # A wrong-type topic is a tool error; a blank or absent topic falls
      # through to the index so the agent can discover what topics exist.
      return tool_error_result(id, "topic must be a string") if topic.present? && !topic.is_a?(String)

      path = if topic.blank?
               "/help"
             else
               # CGI.escape encodes "/" as %2F, so a pasted "../privacy" or
               # "notes/something" gets neutralized — the encoded string
               # can't match any /help/<topic> route and the inner dispatch
               # 404s cleanly.
               "/help/#{CGI.escape(topic)}"
             end

      navigate_and_surface(id, path)
    end

    # Shared implementation for read-only tools that just navigate to a path
    # and return the rendered markdown. execute_action doesn't use this
    # because it needs set_path + execute_action rather than navigate.
    def navigate_and_surface(id, path)
      service = MarkdownUiService.new(tenant: current_tenant, user: @current_token.user)
      result = service.with_provided_token(@plaintext_bearer) { service.navigate(path) }
      surface_dispatch_result(id, result)
    end

    # Reject anything that isn't a relative path under this host. Protocol-
    # relative ("//evil.com") and absolute URLs ("https://...") are not
    # things you should be able to reach through an in-tenant tool.
    def valid_relative_path?(path)
      path.is_a?(String) && path.start_with?("/") && !path.start_with?("//")
    end

    def invalid_path_message
      "Invalid path: must start with '/' and reference a path within this tenant"
    end

    # Strip a query string and any pasted /actions/<name> suffix, leaving the
    # bare resource path. Agents commonly paste the full action URL they see
    # in fetch_page output; we want POSTing to {path}/actions/{action} to
    # land on the right place, not /foo/actions/x/actions/x.
    def normalize_action_path(path)
      result = path.dup
      if (qs = result.index("?"))
        result = result[0...qs] || ""
      end
      if (slash_idx = result.index("/actions/"))
        result = result[0...slash_idx] || ""
      elsif result.end_with?("/actions")
        result = result[0...-"/actions".length] || ""
      end
      result
    end

    # Wrap a MarkdownUiService result into the JSON-RPC tool-result shape.
    #
    # `result` is the Hash returned by MarkdownUiService#navigate or
    # #execute_action. The shape (NavigateResult / ActionResult in that file)
    # is `{ content: String, error: T.nilable(String), ... }`:
    #
    #   - `:content` is the raw HTTP response body from the inner dispatch.
    #     For 2xx it's the markdown the agent wanted; for 4xx/5xx it's the
    #     specific error message the inner controller rendered (e.g.,
    #     "capabilities do not include create_note").
    #   - `:error` is a coarse category derived from the status code
    #     ("Access denied", "Not found", "HTTP 502") — useful only as a
    #     fallback when the body is empty.
    #
    # The body is almost always more actionable than the category, so we
    # prefer it. Both fields are guaranteed populated by MarkdownUiService's
    # Sorbet sigs; if the inner controller renders an empty body for some
    # reason, `presence` falls us back to the category so the agent at
    # least sees something.
    def surface_dispatch_result(id, result)
      if result[:error]
        text = result[:content].presence || result[:error]
        tool_error_result(id, cap_response_body(text))
      else
        jsonrpc_result(id, { content: [{ type: "text", text: cap_response_body(result[:content]) }] })
      end
    end

    # Truncate to max_response_bytes with a visible marker. byteslice + scrub
    # ensures the cut doesn't leave invalid UTF-8.
    def cap_response_body(text)
      limit = self.class.max_response_bytes
      return text if text.bytesize <= limit

      original_size = text.bytesize
      # Reserve a generous chunk for the marker so the final string still
      # fits under the cap.
      marker_room = 200
      truncated = text.byteslice(0, limit - marker_room).to_s.force_encoding(Encoding::UTF_8).scrub
      "#{truncated}\n\n[response truncated — original was #{original_size} bytes, capped at #{limit}]"
    end

    # ====================
    # JSON-RPC envelope helpers
    # ====================

    def jsonrpc_result(id, result)
      { jsonrpc: "2.0", id: id, result: result }
    end

    def jsonrpc_error_envelope(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end

    def tool_error_result(id, message)
      jsonrpc_result(id, {
                       isError: true,
                       content: [{ type: "text", text: message }],
                     })
    end
  end
end
