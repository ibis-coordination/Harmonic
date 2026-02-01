# typed: true

# Renders the markdown UI without requiring a controller/HTTP request context.
# This enables AI agents to navigate the app internally from chat sessions, seeing the same
# markdown interface that external LLMs see via HTTP.
#
# The service provides three main capabilities:
# - Navigation: Render any page as markdown
# - Action discovery: See what actions are available on the current page
# - Action execution: Execute actions (create notes, vote, etc.)
#
# @example Basic navigation
#   service = MarkdownUiService.new(tenant: tenant, superagent: superagent, user: user)
#   result = service.navigate("/studios/team")
#   puts result[:content]  # Rendered markdown
#   puts result[:actions]  # Available actions
#
# @example Execute an action
#   service.navigate("/studios/team/note")
#   result = service.execute_action("create_note", { text: "Hello world" })
#   puts result[:success]  # => true
#
# @example Efficient action execution (no rendering)
#   service.set_path("/studios/team/note")
#   result = service.execute_action("create_note", { text: "Quick note" })
#
# @see MarkdownUiService::ViewContext For template instance variables
# @see MarkdownUiService::ResourceLoader For resource loading logic
# @see MarkdownUiService::ActionExecutor For action execution logic
#
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
    @current_route_info = T.let(nil, T.nilable(T::Hash[Symbol, T.untyped]))
    @view_context = T.let(nil, T.nilable(MarkdownUiService::ViewContext))
  end

  # Navigate to a path and render the markdown view.
  #
  # Validates user access, resolves the route, loads resources, and renders
  # the markdown template. Returns the rendered content along with available actions.
  #
  # The superagent context is dynamically determined from the path. If the path includes
  # a studio handle (e.g., "/studios/green-leaves/note"), the service will switch to
  # that studio's context for this navigation.
  #
  # @param path [String] The URL path to navigate to (e.g., "/studios/team/n/abc123")
  # @param include_layout [Boolean] Whether to include the layout with YAML front matter and nav
  # @return [Hash] Navigation result with :content, :path, :actions, and :error keys
  #
  # @example Navigate with layout
  #   result = service.navigate("/studios/team")
  #   result[:content]  # Full markdown with YAML front matter
  #   result[:actions]  # Array of available action hashes
  #
  # @example Navigate without layout (content only)
  #   result = service.navigate("/studios/team", include_layout: false)
  #   result[:content]  # Just the page content, no nav bar
  sig { params(path: String, include_layout: T::Boolean).returns(NavigateResult) }
  def navigate(path, include_layout: true)
    @current_path = path

    # Resolve route first to extract superagent_handle
    route_info = resolve_route(path)
    return error_result("Route not found: #{path}") unless route_info

    # Dynamically resolve superagent from path if present
    resolve_superagent_from_route(route_info)

    # Validate access after resolving superagent
    access_error = validate_access
    return error_result("Access denied: #{access_error}") if access_error

    with_context do
      @current_route_info = route_info
      @view_context = build_view_context(route_info)

      content = render_markdown(route_info, @view_context, include_layout: include_layout)

      {
        content: content,
        path: path,
        actions: available_actions(route_info),
        error: nil,
      }
    end
  rescue StandardError => e
    error_result("Navigation error: #{e.message}")
  end

  # Set up context for a path without rendering the template.
  #
  # This is more efficient than {#navigate} when you only need to execute actions
  # and don't need the rendered content. Validates access and loads resources
  # but skips template rendering.
  #
  # The superagent context is dynamically determined from the path, same as {#navigate}.
  #
  # @param path [String] The URL path to set up context for
  # @return [Boolean] true if path was valid and context was set up, false otherwise
  #
  # @example Set path then execute action
  #   service.set_path("/studios/team/note")
  #   result = service.execute_action("create_note", { text: "Quick note" })
  sig { params(path: String).returns(T::Boolean) }
  def set_path(path)
    @current_path = path

    # Resolve route first to extract superagent_handle
    route_info = resolve_route(path)
    return false unless route_info

    # Dynamically resolve superagent from path if present
    resolve_superagent_from_route(route_info)

    # Validate access after resolving superagent
    return false if validate_access

    with_context do
      @current_route_info = route_info
      @view_context = build_view_context(route_info)
      true
    end
  rescue StandardError
    false
  end

  # Execute an action at the current path.
  #
  # Requires calling {#navigate} or {#set_path} first to establish context.
  # Delegates to {MarkdownUiService::ActionExecutor} which uses {ApiHelper}
  # for the actual business logic.
  #
  # @param action_name [String] Name of the action to execute (e.g., "create_note", "vote")
  # @param params [Hash] Parameters for the action
  # @return [Hash] Action result with :success, :content, and :error keys
  #
  # @example Create a note
  #   service.navigate("/studios/team/note")
  #   result = service.execute_action("create_note", { text: "Meeting notes" })
  #   result[:success]  # => true
  #   result[:content]  # => "Note created: /studios/team/n/abc123"
  #
  # @example Vote on a decision
  #   service.navigate("/studios/team/d/xyz789")
  #   result = service.execute_action("vote", { vote: "accept" })
  #
  # @raise Returns error result if no path is set
  sig { params(action_name: String, params: T::Hash[Symbol, T.untyped]).returns(ActionResult) }
  def execute_action(action_name, params = {})
    return action_error("No current path - call navigate first") unless @current_path
    return action_error("No view context - call navigate first") unless @view_context

    with_context do
      executor = MarkdownUiService::ActionExecutor.new(
        service: self,
        view_context: @view_context,
        action_name: action_name,
        params: params
      )
      executor.execute
    end
  rescue StandardError => e
    action_error("Action error: #{e.message}")
  end

  private

  sig { params(blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def with_context(&blk)
    # Set thread-local tenant/superagent context
    target_superagent = @superagent || @tenant.main_superagent
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: target_superagent&.handle
    )
    yield
  ensure
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope
  end

  # Resolves the superagent from route params if present.
  # This allows navigation to dynamically switch studio context based on the path.
  # For example, navigating to "/studios/green-leaves/note" will switch to the
  # "green-leaves" studio context.
  sig { params(route_info: T::Hash[Symbol, T.untyped]).void }
  def resolve_superagent_from_route(route_info)
    params = route_info[:params] || {}
    handle = params[:superagent_handle]
    return if handle.blank?

    # Look up the superagent by handle within this tenant
    resolved_superagent = @tenant.superagents.find_by(handle: handle)
    @superagent = resolved_superagent if resolved_superagent
  end

  # Validates that the user has access to the tenant and superagent.
  # Replicates the authorization logic from ApplicationController#validate_authenticated_access.
  # Returns nil if authorized, or an error message if not.
  sig { returns(T.nilable(String)) }
  def validate_access
    target_superagent = @superagent || @tenant.main_superagent

    # Unauthenticated access
    if @user.nil?
      return "Authentication required" if @tenant.require_login?

      return nil # Unauthenticated access allowed for public tenants
    end

    # Check tenant membership
    tenant_user = @tenant.tenant_users.find_by(user: @user)
    return "User is not a member of this tenant" if tenant_user.nil?

    # Check superagent membership (main superagent doesn't require explicit membership)
    return nil if target_superagent&.is_main_superagent?

    superagent_member = target_superagent&.superagent_members&.find_by(user: @user)
    return "User is not a member of this studio" if superagent_member.nil?

    nil # Authorized
  end

  # Raises an error if the user doesn't have access.
  sig { void }
  def validate_access!
    error = validate_access
    raise AuthorizationError, error if error
  end

  # Custom error class for authorization failures
  class AuthorizationError < StandardError; end

  sig { params(path: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def resolve_route(path)
    # Use Rails routing to parse the path
    route_params = Rails.application.routes.recognize_path(path, method: :get)
    {
      controller: route_params[:controller],
      action: route_params[:action],
      params: route_params.except(:controller, :action),
    }
  rescue ActionController::RoutingError
    nil
  end

  sig do
    params(route_info: T::Hash[Symbol, T.untyped]).returns(MarkdownUiService::ViewContext)
  end
  def build_view_context(route_info)
    context = MarkdownUiService::ViewContext.new(
      tenant: @tenant,
      superagent: T.must(@superagent || @tenant.main_superagent),
      user: @user,
      current_path: @current_path
    )

    # Load resources based on the route
    resource_loader = MarkdownUiService::ResourceLoader.new(
      context: context,
      route_info: route_info
    )
    resource_loader.load_resources

    context
  end

  sig do
    params(
      route_info: T::Hash[Symbol, T.untyped],
      context: MarkdownUiService::ViewContext,
      include_layout: T::Boolean
    ).returns(String)
  end
  def render_markdown(route_info, context, include_layout:)
    template = "#{route_info[:controller]}/#{route_info[:action]}"
    layout = include_layout ? "layouts/application" : false

    # Use ApplicationController.renderer which properly handles template compilation
    renderer = ApplicationController.renderer.new(
      http_host: "#{@tenant.subdomain}.#{ENV["HOSTNAME"] || "localhost"}",
      https: false
    )

    content = renderer.render(
      template: template,
      formats: [:md],
      layout: layout,
      assigns: context.to_assigns
    )

    # Log warning if content is unexpectedly empty (helps debug rendering issues)
    if content.blank?
      Rails.logger.warn(
        "[MarkdownUiService] Empty render result for template=#{template}, " \
        "layout=#{layout}, assigns_keys=#{context.to_assigns.keys.join(',')}"
      )
    end

    content
  end

  sig { params(route_info: T::Hash[Symbol, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def available_actions(route_info)
    # Build the route pattern from route info
    pattern = build_route_pattern(route_info)
    actions_info = ActionsHelper.actions_for_route(pattern)
    actions_info&.fetch(:actions, []) || []
  end

  sig { params(route_info: T::Hash[Symbol, T.untyped]).returns(String) }
  def build_route_pattern(route_info)
    controller = route_info[:controller]
    action = route_info[:action]
    route_info[:params]

    case controller
    when "home"
      "/"
    when "studios"
      case action
      when "show"
        "/studios/:studio_handle"
      when "new"
        "/studios/new"
      when "join"
        "/studios/:studio_handle/join"
      when "settings"
        "/studios/:studio_handle/settings"
      when "cycles"
        "/studios/:studio_handle/cycles"
      when "team"
        "/studios/:studio_handle/team"
      else
        "/studios/:studio_handle"
      end
    when "notes"
      case action
      when "new"
        "/studios/:studio_handle/note"
      when "show"
        "/studios/:studio_handle/n/:note_id"
      when "edit"
        "/studios/:studio_handle/n/:note_id/edit"
      else
        "/studios/:studio_handle/n/:note_id"
      end
    when "decisions"
      case action
      when "new"
        "/studios/:studio_handle/decide"
      when "show"
        "/studios/:studio_handle/d/:decision_id"
      when "settings"
        "/studios/:studio_handle/d/:decision_id/settings"
      else
        "/studios/:studio_handle/d/:decision_id"
      end
    when "commitments"
      case action
      when "new"
        "/studios/:studio_handle/commit"
      when "show"
        "/studios/:studio_handle/c/:commitment_id"
      when "settings"
        "/studios/:studio_handle/c/:commitment_id/settings"
      else
        "/studios/:studio_handle/c/:commitment_id"
      end
    when "notifications"
      "/notifications"
    when "users"
      case action
      when "settings"
        "/u/:handle/settings"
      else
        "/u/:handle"
      end
    else
      "/#{controller}/#{action}"
    end
  end

  sig { params(message: String).returns(NavigateResult) }
  def error_result(message)
    {
      content: "",
      path: @current_path || "",
      actions: [],
      error: message,
    }
  end

  sig { params(message: String).returns(ActionResult) }
  def action_error(message)
    {
      success: false,
      content: "",
      error: message,
    }
  end
end
