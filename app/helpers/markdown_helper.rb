# typed: false
# frozen_string_literal: true

# Helper methods for markdown views
module MarkdownHelper
  # Get the available actions for the current route.
  # Returns an array of action hashes with name, description, path, and params.
  # Includes both static actions and conditional actions whose conditions are met.
  def available_actions_for_current_route
    route_pattern = build_route_pattern_from_request
    return [] unless route_pattern

    route_info = ActionsHelper.actions_for_route(route_pattern)
    return [] unless route_info

    # Combine static actions with conditional actions that pass their condition
    all_actions = (route_info[:actions] || []) + evaluate_conditional_actions(route_info)

    # Filter through ActionAuthorization (handles role checks, capabilities, trustee grants, and blocks)
    current_user = instance_variable_get(:@current_user)
    context = build_authorization_context
    collective = instance_variable_get(:@current_collective)
    # Discovery must agree with execute-time enforcement, or the page advertises
    # actions the gate will deny. The public-write guardrail
    # (see ActionContextValidation / CapabilityCheck#public_writes_allowed?) denies
    # any restricted-agent write whose resolved audience is "public" when the
    # owner hasn't enabled allow_public_writes. Strip those here too.
    public_writes_denied = current_user.present? &&
                           !CapabilityCheck.public_writes_allowed?(current_user)
    all_actions.filter_map do |action|
      audience = Mcp::AudienceResolver.resolve(capability_action: action[:name], collective: collective)
      next if audience == "public" && public_writes_denied
      next unless action_allowed_at_this_route?(action, current_user, context)

      build_action_descriptor(action, audience)
    end
  end

  # Render the YAML frontmatter block that opens every markdown page response,
  # reading the page state set by the controller. Delegates to
  # markdown_frontmatter_block, which does the serialization.
  def page_frontmatter
    markdown_frontmatter_block(
      app: "Harmonic",
      host: "#{@current_tenant.subdomain}.#{ENV['HOSTNAME']}",
      path: @current_path,
      scope: @page_scope,
      query: @page_query,
      title: @page_title,
      timestamp: Time.now.utc,
      actions: available_actions_for_current_route,
    )
  end

  # Serialize the page frontmatter to a YAML block, fences included.
  #
  # This frontmatter is a wire protocol: MarkdownUiService, the agent-runner, and
  # any external client parse it with a standard YAML parser, so we EMIT it with a
  # standard YAML emitter (Psych) rather than hand-templating. Psych owns every
  # quoting/escaping decision, which makes scalar injection and silent retyping
  # (a note titled "true" arriving as a boolean) impossible by construction —
  # there is no hand-rolled escaper to get wrong. Returns an html_safe string
  # (the response is text/markdown, not HTML, so YAML's `<`/`>`/`&` must pass
  # through unescaped).
  def markdown_frontmatter_block(app:, host:, path:, title:, timestamp:, scope: nil, query: nil, actions: [])
    data = { "app" => app, "host" => host, "path" => path }
    data["scope"] = scope if scope.present?
    data["query"] = query if query.present?
    data["title"] = title
    data["timestamp"] = timestamp
    data["actions"] = actions.map { |action| frontmatter_action_entry(action) } if actions.any?

    (YAML.dump(data) + "---").html_safe
  end

  MARKDOWN_CONTENT_TRUNCATION_LIMIT = 2_000

  # Truncates content at a line boundary to reduce agent token usage.
  # Returns the original content if under the limit or if full_text=true is passed.
  # Use with markdown_truncation_notice to display the truncation message outside
  # the code fence that wraps user-generated content.
  def truncate_content(content)
    return content if content.blank?
    return content if params[:full_text] == "true"
    return content if content.length <= MARKDOWN_CONTENT_TRUNCATION_LIMIT

    cut_at = content.rindex("\n", MARKDOWN_CONTENT_TRUNCATION_LIMIT) || MARKDOWN_CONTENT_TRUNCATION_LIMIT
    content[0...cut_at]
  end

  # Returns a truncation notice if content was truncated, nil otherwise.
  def markdown_truncation_notice(original_content, truncated_content, url:)
    return nil if original_content == truncated_content

    "... (showing #{truncated_content.length} of #{original_content.length} characters)\nTo view full content, navigate to: #{url}?full_text=true"
  end

  private

  # Shape one action descriptor (symbol keys, from build_action_descriptor) into
  # the string-keyed hash we emit in frontmatter. `params` and a param's
  # `description` are omitted when absent to keep the block lean.
  def frontmatter_action_entry(action)
    entry = {
      "name" => action[:name],
      "visibility" => action[:visibility],
      "description" => action[:description],
    }
    params = Array(action[:params]).map { |param| frontmatter_param_entry(param) }
    entry["params"] = params if params.any?
    entry
  end

  def frontmatter_param_entry(param)
    entry = {
      "name" => param[:name],
      "type" => param[:type],
      "required" => param[:required],
    }
    entry["description"] = param[:description] unless param[:description].nil?
    entry
  end

  def action_allowed_at_this_route?(action, current_user, context)
    decision = context[:resource]
    # Executive/lottery decisions exclude the vote action
    return false if decision.is_a?(Decision) && (decision.is_executive? || decision.is_lottery?) && action[:name] == "vote"

    ActionAuthorization.authorized?(action[:name], current_user, context)
  end

  def build_action_descriptor(action, audience)
    definition = ActionsHelper.action_definition(action[:name])
    {
      name: action[:name],
      visibility: audience,
      description: action[:description] || definition&.dig(:description) || "",
      params: (definition&.dig(:params) || []).map do |param|
        {
          name: param[:name],
          type: param[:type] || "string",
          required: param[:required] != false,
          description: param[:description],
        }
      end,
    }
  end

  # Build the route pattern from the current request.
  # Uses ActionsHelper.route_pattern_for as the single source of truth.
  def build_route_pattern_from_request
    controller_action = "#{params[:controller]}##{params[:action]}"
    ActionsHelper.route_pattern_for(controller_action)
  end

  # Evaluate conditional actions and return those whose conditions are met.
  # Builds a context hash from instance variables for condition evaluation.
  def evaluate_conditional_actions(route_info)
    conditional_actions = route_info[:conditional_actions] || []
    return [] if conditional_actions.empty?

    # Build context from common instance variables
    context = build_condition_context

    conditional_actions.select do |conditional_action|
      condition = conditional_action[:condition]
      next false unless condition.respond_to?(:call)

      begin
        condition.call(context)
      rescue StandardError
        false
      end
    end
  end

  # Build authorization context for ActionAuthorization.authorized?
  def build_authorization_context
    {
      collective: instance_variable_get(:@current_collective),
      resource: instance_variable_get(:@note) ||
                instance_variable_get(:@decision) ||
                instance_variable_get(:@commitment) ||
                instance_variable_get(:@list),
      target_user: instance_variable_get(:@showing_user),
      # The profile user is the subject for both the self and the represent check,
      # matching the execute-time gate (ActionAuthorizationCheck#authorization_context)
      # so discovery and enforcement of :representative rules agree.
      represented_user: instance_variable_get(:@showing_user),
      representation_session: instance_variable_get(:@current_representation_session),
    }
  end

  # Build a context hash from instance variables for conditional action evaluation.
  # Add commonly needed variables here as the conditional actions system grows.
  def build_condition_context
    {
      collective: instance_variable_get(:@current_collective),
      current_heartbeat: instance_variable_get(:@current_heartbeat),
      user: instance_variable_get(:@current_user),
      tenant: instance_variable_get(:@current_tenant),
      resource: instance_variable_get(:@note) ||
                instance_variable_get(:@decision) ||
                instance_variable_get(:@commitment),
      showing_user: instance_variable_get(:@showing_user),
      grant: instance_variable_get(:@grant),
      target_user: instance_variable_get(:@target_user),
    }
  end
end
