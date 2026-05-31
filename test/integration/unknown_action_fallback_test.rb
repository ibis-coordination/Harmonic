require "test_helper"

# When a client POSTs (or GETs) /{path}/actions/{name} and {name} is not
# an explicit action route, Rails routes to a catch-all that returns 404
# with a markdown body listing the actions actually defined at {path}.
# Lets an agent recover from a typo or wrong-resource-type guess in one
# round trip without needing local knowledge of the action namespace.
class UnknownActionFallbackTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @headers = {
      "Authorization" => "Bearer #{@api_token.plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  test "unknown action on note returns 404 with list of valid actions" do
    note = create_note(text: "Test note", collective: @collective, created_by: @user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/totally_made_up_action",
      params: {}.to_json, headers: @headers

    assert_response :not_found
    assert response.content_type.starts_with?("text/markdown")
    assert_includes response.body, "totally_made_up_action"
    # Should list a real action defined for /collectives/:handle/n/:id
    assert_includes response.body, "add_comment"
  end

  test "unknown action on decision returns 404 with list of valid actions" do
    decision = create_decision(question: "Test?", collective: @collective, created_by: @user)

    post "/collectives/#{@collective.handle}/d/#{decision.truncated_id}/actions/some_typo",
      params: {}.to_json, headers: @headers

    assert_response :not_found
    assert_includes response.body, "some_typo"
    assert_includes response.body, "vote"
    assert_includes response.body, "add_options"
  end

  test "valid action still routes to its explicit handler" do
    note = create_note(text: "Test note", collective: @collective, created_by: @user)

    # add_comment is a real action on /n/:id; should succeed, not hit fallback
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/add_comment",
      params: { text: "a comment" }.to_json, headers: @headers

    assert_response :success
    refute_includes response.body, "not a valid action"
  end

  test "unknown action via GET (describe_*) also returns 404 with list" do
    note = create_note(text: "Test note", collective: @collective, created_by: @user)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/no_such_action",
      headers: @headers

    assert_response :not_found
    assert_includes response.body, "no_such_action"
    assert_includes response.body, "add_comment"
  end

  test "conditional actions render with description (falls back to ACTION_DEFINITIONS)" do
    # /collectives/:handle's only conditional action (send_heartbeat) is
    # defined with just :name/:condition — no :description. The handler must
    # fall back to ACTION_DEFINITIONS so the rendered list isn't blank.
    post "/collectives/#{@collective.handle}/actions/bogus",
      params: {}.to_json, headers: @headers

    assert_response :not_found
    assert_includes response.body, "send_heartbeat"
    # Description from ACTION_DEFINITIONS, not blank
    assert_includes response.body, "presence in the collective"
  end

  test "unknown action on unresolved path returns 404 with empty list" do
    post "/totally/fake/path/actions/whatever",
      params: {}.to_json, headers: @headers

    assert_response :not_found
    assert_includes response.body, "whatever"
    assert_includes response.body, "No actions are defined at this path"
  end

  test "capability-restricted user (AI agent) gets 404 teaching error, not 403 capability denial" do
    # Regression for the ActionCapabilityCheck filter: it extracts the action
    # name from the URL and denies on a missing capability before routing
    # reaches the catch-all. If left as-is, agents would see
    # "Your capabilities do not include 'totally_made_up'" — misleading,
    # because the action doesn't exist anywhere. The filter must defer to the
    # catch-all so the agent gets the actually-useful 404 + actions list.
    agent = create_ai_agent(parent: @user, name: "Capability Test Agent")
    agent_token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes)
    agent_headers = {
      "Authorization" => "Bearer #{agent_token.plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    note = create_note(text: "Test note", collective: @collective, created_by: @user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/totally_made_up_action",
      params: {}.to_json, headers: agent_headers

    assert_response :not_found, "should hit the catch-all and return 404, not 403 from capability check"
    assert_includes response.body, "totally_made_up_action"
    assert_includes response.body, "add_comment"
    refute_includes response.body, "capabilities do not include"
  end
end
