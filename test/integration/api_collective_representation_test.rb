# typed: false

require "test_helper"

# Tests for COLLECTIVE representation over the markdown/MCP interface.
#
# Regression coverage for Harmonic#365: a user holding the representative role
# in a collective could not start a collective representation session through
# markdown/MCP because (a) /collectives/:handle/represent had no markdown
# template (406) and (b) there was no start_representation/end_representation
# action surface for the collective (only the HTML form flow).
#
# The trustee (user) representation equivalents live in api_representation_test.rb.
class ApiCollectiveRepresentationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "api-crep-#{SecureRandom.hex(4)}")
    @alice = create_user(email: "alice_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @bob = create_user(email: "bob_#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @tenant.add_user!(@alice)
    @tenant.add_user!(@bob)
    mark_activated!(@alice)
    mark_activated!(@bob)
    @tenant.enable_api!
    @tenant.create_main_collective!(created_by: @alice)
    @collective = create_collective(tenant: @tenant, created_by: @alice, handle: "api-crep-collective-#{SecureRandom.hex(4)}")
    @collective.add_user!(@alice)
    @collective.add_user!(@bob)
    @collective.enable_api!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    @bob_token = ApiToken.create!(
      tenant: @tenant,
      user: @bob,
      scopes: ApiToken.valid_scopes
    )
    @headers = {
      "Authorization" => "Bearer #{@bob_token.plaintext_token}",
      "Accept" => "text/markdown",
    }
    host! "#{@tenant.subdomain}.#{ENV.fetch('HOSTNAME', nil)}"
  end

  def represent_path
    "/collectives/#{@collective.handle}/represent"
  end

  def grant_representative_role!
    @collective.collective_members.find_by(user: @bob).add_role!("representative")
  end

  # Extract the session ID from an action-success body ("Session ID: `uuid`").
  def start_session!
    post "#{represent_path}/actions/start_representation", headers: @headers
    assert_response :success, "Failed to start collective representation: #{response.body}"
    match = response.body.match(/Session ID: `([a-f0-9-]+)`/)
    assert match, "Response should contain session ID: #{response.body}"
    match[1]
  end

  # ---------------------------------------------------------------------------
  # Discovery: the represent page must have a markdown view (no more 406) and
  # must advertise the start_representation action.
  # ---------------------------------------------------------------------------

  test "represent page renders markdown for a representative and lists start_representation" do
    grant_representative_role!

    get represent_path, headers: @headers

    assert_response :success, "represent page should render markdown, not 406: #{response.status}"
    assert_includes response.body, "start_representation",
                     "represent page frontmatter should advertise start_representation"
  end

  # ---------------------------------------------------------------------------
  # Start
  # ---------------------------------------------------------------------------

  test "representative can start a collective representation session via the action" do
    grant_representative_role!

    session_id = start_session!

    session = RepresentationSession.find(session_id)
    assert_equal @collective.id, session.collective_id
    assert_equal @bob.id, session.representative_user_id
    assert_nil session.trustee_grant_id, "should be a collective (not user) representation"
    assert session.active?
  end

  test "non-representative cannot start a collective representation session via the action" do
    post "#{represent_path}/actions/start_representation", headers: @headers

    assert_response :forbidden
    assert_equal 0, RepresentationSession.where(collective: @collective).count
  end

  test "cannot start a second nested collective session" do
    grant_representative_role!
    start_session!

    post "#{represent_path}/actions/start_representation",
         headers: @headers.merge("X-Representation-Session-ID" => RepresentationSession.last.id,
                                 "X-Representing-Collective" => @collective.handle)

    assert_response :conflict
  end

  # ---------------------------------------------------------------------------
  # End
  # ---------------------------------------------------------------------------

  test "representative can end a collective representation session via the action" do
    grant_representative_role!
    session_id = start_session!

    post "#{represent_path}/actions/end_representation",
         headers: @headers.merge("X-Representation-Session-ID" => session_id,
                                 "X-Representing-Collective" => @collective.handle)

    assert_response :success, "Failed to end collective representation: #{response.body}"
    assert RepresentationSession.find(session_id).ended?, "session should be ended"
  end

  test "ending with no active session returns not found" do
    grant_representative_role!

    post "#{represent_path}/actions/end_representation", headers: @headers

    assert_response :not_found
  end

  # ---------------------------------------------------------------------------
  # Nested-session guard is DB-backed, not header-dependent (#365 review, #1)
  # ---------------------------------------------------------------------------

  # The header-only guard (`current_representation_session`) is bypassable: an
  # API caller need not echo X-Representation-Session-ID on start, so a second
  # start without the header would sail past it and create a second concurrent
  # active session. The DB existence check must catch it.
  test "cannot start a second collective session without echoing the session header" do
    grant_representative_role!
    start_session!

    # Second start with NO representation header at all.
    post "#{represent_path}/actions/start_representation", headers: @headers

    assert_response :conflict
    assert_equal 1, RepresentationSession.where(collective: @collective, ended_at: nil).count,
                 "a duplicate concurrent session must not be created"
  end

  # ---------------------------------------------------------------------------
  # AI-agent callers: exercise the capability layer (the actual #365 scenario).
  # The human-token tests above never hit CapabilityCheck because restricted_user?
  # is false for a human. (#365 review, #5)
  # ---------------------------------------------------------------------------

  # An AI agent representing @alice, added to the collective with the
  # representative role. `capabilities: nil` means "all grantable" (the default);
  # pass an array to restrict what the agent may do.
  def agent_headers(capabilities:)
    config = { "mode" => "internal" }
    config["capabilities"] = capabilities unless capabilities.nil?
    agent = create_ai_agent(parent: @alice, name: "Rep Agent #{SecureRandom.hex(4)}", agent_configuration: config)
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    @collective.collective_members.find_by(user: agent).add_role!("representative")
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes)
    {
      "Authorization" => "Bearer #{token.plaintext_token}",
      "Accept" => "text/markdown",
    }
  end

  test "agent with full capabilities can start a collective session" do
    headers = agent_headers(capabilities: nil)

    post "#{represent_path}/actions/start_representation", headers: headers

    assert_response :success
    assert_equal 1, RepresentationSession.where(collective: @collective, ended_at: nil).count
  end

  test "agent lacking start_representation capability is denied by the capability layer" do
    headers = agent_headers(capabilities: ["create_note", "end_representation"])

    post "#{represent_path}/actions/start_representation", headers: headers

    assert_response :forbidden
    assert_equal 0, RepresentationSession.where(collective: @collective).count,
                 "capability-denied start must not create a session"
  end

  # #3: end_representation routes through the capability layer, so an agent that
  # can start but not end would get locked into a session until expiry. Refuse
  # the start up front instead.
  test "agent lacking end_representation capability is refused at start to avoid a lockout" do
    headers = agent_headers(capabilities: ["create_note", "start_representation"])

    post "#{represent_path}/actions/start_representation", headers: headers

    assert_response :forbidden
    assert_match(/end_representation/, response.body,
                 "should explain the missing end capability")
    assert_equal 0, RepresentationSession.where(collective: @collective).count
  end
end
