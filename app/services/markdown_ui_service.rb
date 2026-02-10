# typed: true
# frozen_string_literal: true

# MarkdownUiService using internal HTTP request dispatch.
#
# This version dispatches requests through the Rails stack using ActionDispatch::Integration::Session,
# eliminating the need to duplicate route resolution, resource loading, and rendering logic.
# Internal agents see exactly the same responses that external API clients see.
#
# @see MarkdownUiService For the original implementation (to be replaced)
class MarkdownUiService
  extend T::Sig

  # Navigation result structure
  NavigateResult = T.type_alias do
    {
      content: String,
      path: String,
      actions: T::Array[T::Hash[Symbol, T.untyped]],
      error: T.nilable(String),
    }
  end

  # Action execution result structure
  ActionResult = T.type_alias do
    {
      success: T::Boolean,
      content: String,
      error: T.nilable(String),
    }
  end

  sig { returns(Tenant) }
  attr_reader :tenant

  sig { returns(T.nilable(Superagent)) }
  attr_reader :superagent

  sig { returns(T.nilable(User)) }
  attr_reader :user

  sig { returns(T.nilable(String)) }
  attr_reader :current_path

  sig do
    params(
      tenant: Tenant,
      superagent: T.nilable(Superagent),
      user: T.nilable(User)
    ).void
  end
  def initialize(tenant:, superagent: nil, user: nil)
    @tenant = tenant
    @superagent = superagent
    @user = user
    @current_path = T.let(nil, T.nilable(String))
    @token = T.let(nil, T.nilable(ApiToken))
    @plaintext_token = T.let(nil, T.nilable(String))
    @session = T.let(nil, T.nilable(ActionDispatch::Integration::Session))
  end

  # Execute a block with an ephemeral internal token.
  # The token is created at the start of the block and destroyed when the block completes.
  # This ensures tokens only exist during active task execution.
  #
  # @yield The block to execute with the internal token available
  # @return The return value of the block
  sig do
    type_parameters(:T)
      .params(blk: T.proc.returns(T.type_parameter(:T)))
      .returns(T.type_parameter(:T))
  end
  def with_internal_token(&blk)
    raise ArgumentError, "User required for internal token" unless @user

    @token = ApiToken.create_internal_token(user: @user, tenant: @tenant)
    @plaintext_token = @token.plaintext_token
    yield
  ensure
    @token&.destroy
    @token = nil
    @plaintext_token = nil
  end

  # Navigate to a path and render the markdown view.
  #
  # Dispatches an internal GET request through the Rails stack with Accept: text/markdown.
  # Returns the rendered content along with actions parsed from YAML frontmatter.
  #
  # @param path [String] The URL path to navigate to (e.g., "/studios/team/n/abc123")
  # @param include_layout [Boolean] Ignored in V2 - layout is always included from the server
  # @return [Hash] Navigation result with :content, :path, :actions, and :error keys
  sig { params(path: String, include_layout: T::Boolean).returns(NavigateResult) }
  def navigate(path, include_layout: true)
    @current_path = path

    result = dispatch_get(path)

    if result[:success]
      {
        content: result[:content],
        path: path,
        actions: result[:actions],
        error: nil,
      }
    else
      {
        content: result[:content] || "",
        path: path,
        actions: [],
        error: result[:error],
      }
    end
  rescue StandardError => e
    {
      content: "",
      path: path,
      actions: [],
      error: "Navigation error: #{e.message}",
    }
  end

  # Set up context for a path without rendering the template.
  #
  # In V2, this just stores the path - no actual request is made until needed.
  # This is more efficient when you only need to execute actions.
  #
  # @param path [String] The URL path to set up context for
  # @return [Boolean] Always returns true in V2 (validation happens on execute)
  sig { params(path: String).returns(T::Boolean) }
  def set_path(path)
    @current_path = path
    true
  end

  # Execute an action at the current path.
  #
  # Dispatches an internal POST request to the action endpoint.
  # The endpoint is constructed as: {current_path}/actions/{action_name}
  #
  # @param action_name [String] Name of the action to execute (e.g., "create_note", "vote")
  # @param params [Hash] Parameters for the action
  # @return [Hash] Action result with :success, :content, and :error keys
  sig { params(action_name: String, params: T::Hash[Symbol, T.untyped]).returns(ActionResult) }
  def execute_action(action_name, params = {})
    return { success: false, content: "", error: "No current path - call navigate first" } unless @current_path

    # If we're already on the action description page, POST directly to it
    # Otherwise, append /actions/{action_name} to the current path
    action_suffix = "/actions/#{action_name}"
    action_path = if @current_path.end_with?(action_suffix)
                    @current_path
                  else
                    "#{@current_path}#{action_suffix}"
                  end
    result = dispatch_post(action_path, params)

    {
      success: result[:success],
      content: result[:content] || "",
      error: result[:error],
    }
  rescue StandardError => e
    {
      success: false,
      content: "",
      error: "Action error: #{e.message}",
    }
  end

  private

  # Dispatch a GET request through the Rails stack
  sig { params(path: String).returns(T::Hash[Symbol, T.untyped]) }
  def dispatch_get(path)
    ensure_session!
    ensure_token!

    session.get(path, headers: request_headers)

    build_response
  end

  # Dispatch a POST request through the Rails stack
  sig { params(path: String, params: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def dispatch_post(path, params)
    ensure_session!
    ensure_token!

    session.post(path, params: params.to_json, headers: request_headers)

    build_response
  end

  # Build the Integration::Session lazily
  sig { void }
  def ensure_session!
    return if @session

    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host = "#{@tenant.subdomain}.#{ENV['HOSTNAME'] || 'localhost'}"
  end

  sig { returns(ActionDispatch::Integration::Session) }
  def session
    T.must(@session)
  end

  # Create an internal API token for authentication if one doesn't exist.
  # Prefers ephemeral token from with_internal_token block.
  sig { void }
  def ensure_token!
    return if @plaintext_token.present?
    return if @token
    return unless @user

    @token = ApiToken.create_internal_token(user: @user, tenant: @tenant)
    @plaintext_token = @token.plaintext_token
  end

  # Build request headers with Accept: text/markdown and Bearer auth
  sig { returns(T::Hash[String, String]) }
  def request_headers
    headers = {
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
      # Tell Rails we're already on HTTPS (like a reverse proxy would)
      # Without this, force_ssl in production causes 301 redirects
      "X-Forwarded-Proto" => "https",
    }

    if @plaintext_token.present?
      headers["Authorization"] = "Bearer #{@plaintext_token}"
    end

    headers
  end

  # Build a result hash from the session response
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def build_response
    status = session.response.status
    body = session.response.body

    if status >= 200 && status < 300
      frontmatter = parse_frontmatter(body)
      {
        success: true,
        content: body,
        actions: frontmatter["actions"] || [],
        error: nil,
      }
    elsif status == 401
      {
        success: false,
        content: body,
        actions: [],
        error: "Authentication required",
      }
    elsif status == 403
      {
        success: false,
        content: body,
        actions: [],
        error: "Access denied",
      }
    elsif status == 404
      {
        success: false,
        content: body,
        actions: [],
        error: "Not found",
      }
    else
      {
        success: false,
        content: body,
        actions: [],
        error: "HTTP #{status}",
      }
    end
  end

  # Parse YAML frontmatter from markdown content
  sig { params(content: String).returns(T::Hash[String, T.untyped]) }
  def parse_frontmatter(content)
    return {} unless content.start_with?("---\n")

    end_index = content.index("\n---\n", 4)
    return {} unless end_index

    yaml_content = T.must(content[4...end_index])
    YAML.safe_load(yaml_content, permitted_classes: [Symbol, Time]) || {}
  rescue Psych::SyntaxError
    {}
  end
end
