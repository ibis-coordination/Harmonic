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

  # The page body must agree with the frontmatter even when the caller does not
  # echo X-Representation-Session-ID (nothing requires the header on this page).
  # The frontmatter lambdas are DB-backed, so the prose must be too — otherwise
  # an agent mid-session is told it can start while only end_representation is
  # advertised.
  test "represent page reflects an active session without the session header" do
    grant_representative_role!
    session_id = start_session!

    get represent_path, headers: @headers

    assert_response :success
    assert_includes response.body, "end_representation"
    assert_includes response.body, session_id,
                    "page should surface the active session's ID"
    refute_match(/you can start a session/, response.body,
                 "page must not offer to start while a session is active")
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
  # Acting under the session across collective contexts (#402)
  #
  # resolve_api_representation looked the session up under the collective default
  # scope. RepresentationSession is MightNotBelongToCollective, so a *collective*
  # session (collective_id = the represented collective) is scoped out whenever
  # the request's Collective.current_id is anything else -> the lookup returns
  # nil and the caller gets "Invalid representation session ID".
  #
  # The start/end tests above never hit this: they act on the represented
  # collective's own /represent path, where the current-collective context
  # matches and the default scope happens to include the row. The bug only
  # surfaces when acting under the session on a DIFFERENT collective context
  # (a second collective, or the public space) — exactly what an agent does when
  # it starts a session to post an announcement somewhere other than the
  # collective's own page.
  # ---------------------------------------------------------------------------

  test "collective session resolves when acting on a different collective's context" do
    grant_representative_role!
    session_id = start_session!

    # A second collective forces a different Collective.current_id on the request.
    # The acting identity (the represented collective's identity_user) is a member
    # so the target page authorizes cleanly once representation resolves.
    other = create_collective(tenant: @tenant, created_by: @alice,
                              handle: "api-crep-other-#{SecureRandom.hex(4)}")
    other.add_user!(@alice)
    other.add_user!(@collective.identity_user)
    other.enable_api!

    get other.path, headers: @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-Collective" => @collective.handle,
    )

    assert_response :success,
                    "collective session must resolve regardless of the request's collective " \
                    "context, but got #{response.status}: #{response.body[0..300]}"
    refute_includes response.body, "Invalid representation session ID",
                     "the session lookup must not be scoped out by the differing collective context"
    assert_includes response.body, "acting on behalf of",
                    "the response should reflect that the caller is acting under the collective session"
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

  # ---------------------------------------------------------------------------
  # Posting publicly at the root as the collective (#469)
  #
  # A human representative can post a public note at the main-collective root
  # (/note) as the collective, but an AI-agent representative got
  # "not authorized to perform 'create_note'". The acting identity is the
  # represented collective's identity_user, which holds no CollectiveMember row
  # on the main collective — so the :collective_member gate denied it over
  # markdown/MCP even though the browser HTML flow authorizes exactly this.
  # ---------------------------------------------------------------------------
  test "agent representative can create a public note at the root as the collective" do
    @tenant.main_collective.enable_api!

    # The agent has public writes enabled (the #467 guardrail its owner toggled
    # on) — so this exercises the *later* #469 gate, not that one.
    agent = create_ai_agent(parent: @alice, name: "Pub Agent #{SecureRandom.hex(4)}",
                            agent_configuration: { "mode" => "internal", "allow_public_writes" => true })
    @tenant.add_user!(agent)
    @collective.add_user!(agent)
    @collective.collective_members.find_by(user: agent).add_role!("representative")
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes)
    headers = {
      "Authorization" => "Bearer #{token.plaintext_token}",
      "Accept" => "text/markdown",
    }

    post "#{represent_path}/actions/start_representation", headers: headers
    assert_response :success, "start failed: #{response.body}"
    session_id = response.body.match(/Session ID: `([a-f0-9-]+)`/)[1]

    rep_headers = headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-Collective" => @collective.handle,
    )

    assert_difference -> { Note.count }, 1 do
      post "/note/actions/create_note",
           params: { text: "Public announcement from the collective." },
           headers: rep_headers
    end

    assert_response :success, "root create_note under collective representation must succeed: #{response.body}"
    note = Note.order(:created_at).last
    assert_equal @collective.identity_user_id, note.created_by_id,
                 "the note must be attributed to the collective identity, not the agent"
    assert note.collective.is_main_collective?, "the note must land on the public main collective"
  end
end
