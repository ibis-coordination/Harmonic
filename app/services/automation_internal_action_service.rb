# typed: true

# Executes internal actions for studio automations.
# Uses MarkdownUiService to dispatch actions through the full Rails stack,
# acting as the studio's identity user.
#
# Supported actions:
# - create_note: Create a new note in the studio
# - create_decision: Create a new decision
# - create_commitment: Create a new commitment
#
# Resources created by this service are automatically tagged with the
# automation_rule_run_id for traceability.
class AutomationInternalActionService
  extend T::Sig

  SUPPORTED_ACTIONS = %w[
    create_note
    create_decision
    create_commitment
  ].freeze

  # Action configuration: maps action names to their paths and required params
  ACTION_CONFIG = T.let({
    "create_note" => {
      path_suffix: "/note",
      action_name: "create_note",
      param_mapping: {
        "text" => :text,
        "title" => :title,
      },
    },
    "create_decision" => {
      path_suffix: "/decision",
      action_name: "create_decision",
      param_mapping: {
        "question" => :question,
        "description" => :description,
        "deadline" => :deadline,
        "options" => :options,
      },
    },
    "create_commitment" => {
      path_suffix: "/commitment",
      action_name: "create_commitment",
      param_mapping: {
        "title" => :title,
        "description" => :description,
        "critical_mass" => :critical_mass,
        "deadline" => :deadline,
        "limit" => :limit,
      },
    },
  }.freeze, T::Hash[String, T::Hash[Symbol, T.untyped]])

  class Result < T::Struct
    const :success, T::Boolean
    const :message, String
    const :resource_id, T.nilable(String)
    const :resource_path, T.nilable(String)
    const :error, T.nilable(String)
  end

  sig { params(run: AutomationRuleRun).void }
  def initialize(run)
    @run = run
    @rule = T.let(T.must(run.automation_rule), AutomationRule)
    @collective = T.let(run.collective, T.nilable(Collective))
  end

  sig { params(action_name: String, params: T::Hash[String, T.untyped]).returns(Result) }
  def execute(action_name, params)
    # Validate action is supported
    unless SUPPORTED_ACTIONS.include?(action_name)
      return Result.new(
        success: false,
        message: "Action executed",
        error: "Unsupported action: #{action_name}. Supported actions: #{SUPPORTED_ACTIONS.join(", ")}"
      )
    end

    # Validate collective exists for studio rules
    unless @collective
      return Result.new(
        success: false,
        message: "Action executed",
        error: "Internal actions require a studio context"
      )
    end

    # Get the studio's identity user
    identity_user = @collective.identity_user
    unless identity_user
      return Result.new(
        success: false,
        message: "Action executed",
        error: "Studio does not have an identity user configured"
      )
    end

    # Execute with automation context so created resources are tracked
    AutomationContext.with_run(@run) do
      execute_action_as_identity(action_name, params, identity_user)
    end
  rescue StandardError => e
    Rails.logger.error("AutomationInternalActionService error: #{e.message}")
    Result.new(
      success: false,
      message: "Action failed",
      error: e.message
    )
  end

  private

  sig { params(action_name: String, params: T::Hash[String, T.untyped], identity_user: User).returns(Result) }
  def execute_action_as_identity(action_name, params, identity_user)
    config = ACTION_CONFIG[action_name]
    return Result.new(success: false, message: "Action failed", error: "Unknown action config") unless config

    tenant = @rule.tenant

    # Build the path to the action
    studio_path = "/studios/#{@collective&.handle}#{config[:path_suffix]}"

    # Create the markdown UI service with the identity user
    service = MarkdownUiService.new(
      tenant: T.must(tenant),
      collective: @collective,
      user: identity_user
    )

    # Map params to the expected format
    action_params = map_params(params, T.must(config[:param_mapping]))

    # Execute the action
    service.with_internal_token do
      # First, navigate to set up context
      service.set_path(studio_path)

      # Execute the action
      result = service.execute_action(config[:action_name].to_s, action_params)

      if result[:success]
        # Parse the result to extract resource info
        resource_info = extract_resource_info(result[:content])

        Result.new(
          success: true,
          message: "#{action_name.humanize} completed successfully",
          resource_id: resource_info[:id],
          resource_path: resource_info[:path]
        )
      else
        Result.new(
          success: false,
          message: "Action failed",
          error: result[:error] || "Unknown error"
        )
      end
    end
  end

  sig { params(params: T::Hash[String, T.untyped], mapping: T::Hash[String, Symbol]).returns(T::Hash[Symbol, T.untyped]) }
  def map_params(params, mapping)
    result = {}
    mapping.each do |yaml_key, action_key|
      value = params[yaml_key]
      result[action_key] = value if value.present?
    end
    result
  end

  # Extract resource ID and path from the action result content
  sig { params(content: String).returns(T::Hash[Symbol, T.nilable(String)]) }
  def extract_resource_info(content)
    # The action result typically contains a redirect_to or link to the created resource
    # Parse the content to find resource identifiers

    # Look for truncated IDs in the response (8 characters)
    id_match = content.match(%r{/[ndc]/([a-f0-9]{8})}i)
    path_match = content.match(%r{(/studios/[^/]+/[ndc]/[a-f0-9]{8})}i)

    {
      id: id_match&.[](1),
      path: path_match&.[](1),
    }
  end
end
