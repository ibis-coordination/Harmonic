require "test_helper"

class ActionsHelperTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )
  end

  # ==========================================================================
  # ACTION_DEFINITIONS structure tests
  # ==========================================================================

  test "ACTION_DEFINITIONS is a non-empty hash" do
    assert_instance_of Hash, ActionsHelper::ACTION_DEFINITIONS
    assert ActionsHelper::ACTION_DEFINITIONS.any?, "ACTION_DEFINITIONS should not be empty"
  end

  test "all action definitions have required keys" do
    required_keys = [:description, :params_string, :params, :authorization]

    ActionsHelper::ACTION_DEFINITIONS.each do |name, definition|
      required_keys.each do |key|
        assert definition.key?(key),
          "Action '#{name}' must have :#{key} defined"
      end
    end
  end

  test "all action definitions have valid description" do
    ActionsHelper::ACTION_DEFINITIONS.each do |name, definition|
      assert_instance_of String, definition[:description],
        "Action '#{name}' description must be a String"
      assert definition[:description].present?,
        "Action '#{name}' description must not be empty"
    end
  end

  test "all action definitions have valid params_string" do
    ActionsHelper::ACTION_DEFINITIONS.each do |name, definition|
      assert_instance_of String, definition[:params_string],
        "Action '#{name}' params_string must be a String"
      assert definition[:params_string].start_with?("("),
        "Action '#{name}' params_string must start with '('"
      assert definition[:params_string].end_with?(")"),
        "Action '#{name}' params_string must end with ')'"
    end
  end

  test "all action definitions have valid params array" do
    ActionsHelper::ACTION_DEFINITIONS.each do |name, definition|
      assert_instance_of Array, definition[:params],
        "Action '#{name}' params must be an Array"

      definition[:params].each_with_index do |param, idx|
        assert_instance_of Hash, param,
          "Action '#{name}' param #{idx} must be a Hash"
        assert param.key?(:name),
          "Action '#{name}' param #{idx} must have :name"
        assert param.key?(:type),
          "Action '#{name}' param #{idx} must have :type"
        assert param.key?(:description),
          "Action '#{name}' param #{idx} must have :description"
      end
    end
  end

  # ==========================================================================
  # Route mapping tests
  # ==========================================================================

  test "actions_by_route is a non-empty hash" do
    routes = ActionsHelper.actions_by_route
    assert_instance_of Hash, routes
    assert routes.any?, "actions_by_route should not be empty"
  end

  test "all route mappings have required keys" do
    ActionsHelper.actions_by_route.each do |route, config|
      assert config.key?(:controller_actions),
        "Route '#{route}' must have :controller_actions"
      assert config.key?(:actions),
        "Route '#{route}' must have :actions"
    end
  end

  test "all route actions reference valid action definitions" do
    ActionsHelper.actions_by_route.each do |route, config|
      config[:actions].each do |action|
        assert action.key?(:name),
          "Action in route '#{route}' must have :name"
        action_name = action[:name]

        # Verify action exists in ACTION_DEFINITIONS
        assert ActionsHelper::ACTION_DEFINITIONS.key?(action_name),
          "Action '#{action_name}' in route '#{route}' must exist in ACTION_DEFINITIONS"
      end
    end
  end

  test "routes_and_actions is a sorted array" do
    routes = ActionsHelper.routes_and_actions
    assert_instance_of Array, routes

    route_strings = routes.map { |r| r[:route] }
    assert_equal route_strings, route_strings.sort,
      "routes_and_actions should be sorted alphabetically by route"
  end

  # ==========================================================================
  # action_definition method tests
  # ==========================================================================

  test "action_definition returns definition for valid action" do
    definition = ActionsHelper.action_definition("create_note")
    assert_not_nil definition
    assert_equal "Create a new note", definition[:description]
    assert_instance_of String, definition[:params_string]
    assert_instance_of Array, definition[:params]
  end

  test "action_definition returns nil for unknown action" do
    definition = ActionsHelper.action_definition("nonexistent_action")
    assert_nil definition
  end

  # ==========================================================================
  # action_description method tests
  # ==========================================================================

  test "action_description returns hash with required keys" do
    result = ActionsHelper.action_description("create_note")

    assert_instance_of Hash, result
    assert_equal "create_note", result[:action_name]
    assert_nil result[:resource]
    assert_equal "Create a new note", result[:description]
    assert_instance_of Array, result[:params]
  end

  test "action_description includes resource when provided" do
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      text: "Test note"
    )

    result = ActionsHelper.action_description("update_note", resource: note)
    assert_equal note, result[:resource]
  end

  test "action_description allows description override" do
    custom_description = "My custom description"
    result = ActionsHelper.action_description("create_note", description_override: custom_description)
    assert_equal custom_description, result[:description]
  end

  test "action_description allows params override" do
    custom_params = [{ name: "custom", type: "string", description: "Custom param" }]
    result = ActionsHelper.action_description("create_note", params_override: custom_params)
    assert_equal custom_params, result[:params]
  end

  test "action_description raises ArgumentError for unknown action" do
    assert_raises ArgumentError do
      ActionsHelper.action_description("nonexistent_action")
    end
  end

  # ==========================================================================
  # actions_for_route method tests
  # ==========================================================================

  test "actions_for_route returns config for valid route" do
    config = ActionsHelper.actions_for_route("/studios/:studio_handle")
    assert_not_nil config
    assert config.key?(:actions)
    assert config.key?(:controller_actions)
  end

  test "actions_for_route returns nil for unknown route" do
    config = ActionsHelper.actions_for_route("/nonexistent/route")
    assert_nil config
  end

  test "actions_for_route returns expected actions for studio join route" do
    config = ActionsHelper.actions_for_route("/studios/:studio_handle/join")
    action_names = config[:actions].map { |a| a[:name] }

    # Studio join route should have join_studio action
    assert_includes action_names, "join_studio"
  end

  # ==========================================================================
  # route_pattern_for method tests
  # ==========================================================================

  test "route_pattern_for returns route for valid controller action" do
    route = ActionsHelper.route_pattern_for("notes#show")
    assert_equal "/studios/:studio_handle/n/:note_id", route
  end

  test "route_pattern_for returns nil for unknown controller action" do
    route = ActionsHelper.route_pattern_for("nonexistent#action")
    assert_nil route
  end

  test "route_pattern_for maps trustee_grants controller actions" do
    assert_equal "/u/:handle/settings/trustee-grants",
      ActionsHelper.route_pattern_for("trustee_grants#index")
    assert_equal "/u/:handle/settings/trustee-grants/new",
      ActionsHelper.route_pattern_for("trustee_grants#new")
    assert_equal "/u/:handle/settings/trustee-grants/:grant_id",
      ActionsHelper.route_pattern_for("trustee_grants#show")
  end

  # ==========================================================================
  # routes_and_actions_for_user method tests
  # ==========================================================================

  test "routes_and_actions_for_user returns filtered routes" do
    routes = ActionsHelper.routes_and_actions_for_user(@user)
    assert_instance_of Array, routes

    # Each route should have :route and :actions keys
    routes.each do |route_info|
      assert route_info.key?(:route)
      assert route_info.key?(:actions)
    end
  end

  test "routes_and_actions_for_user excludes routes with no visible actions" do
    routes = ActionsHelper.routes_and_actions_for_user(@user)

    routes.each do |route_info|
      assert route_info[:actions].any?,
        "Route '#{route_info[:route]}' should not be included if it has no visible actions"
    end
  end

  test "routes_and_actions_for_user returns empty for nil user" do
    routes = ActionsHelper.routes_and_actions_for_user(nil)

    # Some routes may still be visible (public actions), but most should be filtered
    # At minimum, authenticated-only actions should be excluded
    action_names = routes.flat_map { |r| r[:actions].map { |a| a[:name] } }
    refute_includes action_names, "create_studio"
  end

  # ==========================================================================
  # Trustee grant action definitions tests
  # ==========================================================================

  test "trustee grant actions are defined in ACTION_DEFINITIONS" do
    trustee_actions = %w[
      create_trustee_grant
      accept_trustee_grant
      decline_trustee_grant
      revoke_trustee_grant
      start_representation
    ]

    trustee_actions.each do |action_name|
      assert ActionsHelper::ACTION_DEFINITIONS.key?(action_name),
        "Action '#{action_name}' must be defined in ACTION_DEFINITIONS"
    end
  end

  test "trustee grant show route includes all trustee actions" do
    config = ActionsHelper.actions_for_route("/u/:handle/settings/trustee-grants/:grant_id")
    assert_not_nil config, "Trustee grant show route must exist"

    action_names = config[:actions].map { |a| a[:name] }

    expected_actions = %w[
      accept_trustee_grant
      decline_trustee_grant
      revoke_trustee_grant
      start_representation
    ]

    expected_actions.each do |expected|
      assert_includes action_names, expected,
        "Trustee grant show route must include '#{expected}' action"
    end
  end

  test "trustee grant new route includes create action" do
    config = ActionsHelper.actions_for_route("/u/:handle/settings/trustee-grants/new")
    assert_not_nil config

    action_names = config[:actions].map { |a| a[:name] }
    assert_includes action_names, "create_trustee_grant"
  end

  # ==========================================================================
  # Consistency tests
  # ==========================================================================

  test "all actions in routes have matching params_string from definitions" do
    ActionsHelper.actions_by_route.each do |route, config|
      config[:actions].each do |action|
        action_name = action[:name]
        definition = ActionsHelper::ACTION_DEFINITIONS[action_name]
        next unless definition # Already tested that all actions exist

        assert_equal definition[:params_string], action[:params_string],
          "Action '#{action_name}' in route '#{route}' params_string must match definition"
      end
    end
  end

  test "all actions in routes have matching description from definitions" do
    ActionsHelper.actions_by_route.each do |route, config|
      config[:actions].each do |action|
        action_name = action[:name]
        definition = ActionsHelper::ACTION_DEFINITIONS[action_name]
        next unless definition # Already tested that all actions exist

        assert_equal definition[:description], action[:description],
          "Action '#{action_name}' in route '#{route}' description must match definition"
      end
    end
  end
end
