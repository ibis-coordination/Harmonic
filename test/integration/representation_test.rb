require "test_helper"

class RepresentationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @parent = @global_user
    @ai_agent = create_ai_agent(parent: @parent, name: "AiAgent User")
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
    # The TrusteeGrant is auto-created when the ai_agent is created
    @grant = TrusteeGrant.find_by!(granting_user: @ai_agent, trustee_user: @parent)
    # After the migration:
    # - trustee_user = the parent (the person trusted to act)
    # - granting_user = the ai_agent (the person being represented)
    # - effective_user = the granting_user (ai_agent) - content is attributed to them
    @effective_user = @grant.granting_user  # = @ai_agent
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # Helper to start representation and handle the flow
  def start_representing
    post "/u/#{@ai_agent.handle}/represent"
    assert_response :redirect
    # Flow redirects to /representing first
    follow_redirect!
  end

  # ====================
  # Starting Representation
  # ====================

  test "parent can start representing their ai_agent user" do
    sign_in_as(@parent, tenant: @tenant)

    start_representing

    # Now at /representing page
    assert_response :success
    # Verify a RepresentationSession was created
    assert RepresentationSession.exists?(trustee_grant: @grant, representative_user: @parent)
  end

  test "parent cannot represent another user's ai_agent user" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    @collective.add_user!(other_parent)
    other_ai_agent = create_ai_agent(parent: other_parent, name: "Other AiAgent")
    @tenant.add_user!(other_ai_agent)
    @collective.add_user!(other_ai_agent)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_ai_agent.handle}/represent"

    assert_response :forbidden
  end

  test "parent cannot represent archived ai_agent user" do
    # Archive through tenant_user since archived_at is on TenantUser
    @ai_agent.tenant_user = @tenant.tenant_users.find_by(user: @ai_agent)
    @ai_agent.archive!
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@ai_agent.handle}/represent"

    assert_response :forbidden
  end

  test "parent cannot represent a regular person user" do
    other_person = create_user(name: "Other Person")
    @tenant.add_user!(other_person)
    @collective.add_user!(other_person)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_person.handle}/represent"

    assert_response :forbidden
  end

  test "unauthenticated user cannot represent anyone" do
    post "/u/#{@ai_agent.handle}/represent"

    # Should redirect to login or return error
    assert_response :redirect
  end

  # ====================
  # Session Management
  # ====================

  test "after representation starts current_user returns the trustee user" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    # Access a page that shows current user info (non-home pages work normally)
    get "/studios/#{@collective.handle}"

    assert_response :success
  end

  test "creating content while representing attributes it to the represented user" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    # Create a note while representing
    post "/studios/#{@collective.handle}/note", params: {
      note: {
        title: "Note from representation",
        text: "This should be attributed to the ai_agent (the person being represented)",
      },
    }

    note = Note.last
    # Content is attributed to the effective_user (the ai_agent being represented)
    assert_equal @effective_user.id, note.created_by_id
    assert_equal @ai_agent.id, note.created_by_id
    assert_not_equal @parent.id, note.created_by_id
  end

  # ====================
  # Actions While Representing
  # ====================

  test "creating a note while representing attributes it to the represented user" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    assert_difference "Note.count", 1 do
      post "/studios/#{@collective.handle}/note", params: {
        note: {
          title: "Note created while representing",
          text: "Created by parent representing ai_agent",
        },
      }
    end

    note = Note.last
    # Content is attributed to the effective_user (the ai_agent being represented)
    assert_equal @effective_user.id, note.created_by_id
  end

  test "voting on a decision while representing records the represented user's participation" do
    sign_in_as(@parent, tenant: @tenant)

    # Create a decision first
    decision = Decision.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @parent,
      question: "Test Decision?",
      description: "Testing voting while representing",
      deadline: Time.current + 1.week,
      options_open: true,
    )
    option = Option.create!(
      tenant: @tenant,
      collective: @collective,
      decision: decision,
      decision_participant: DecisionParticipantManager.new(decision: decision, user: @parent).find_or_create_participant,
      title: "Option A",
    )

    # Now represent and vote
    start_representing

    post "/studios/#{@collective.handle}/d/#{decision.truncated_id}/actions/vote", params: {
      votes: [{ option_title: option.title, accept: true, prefer: false }],
    }

    # Check that the vote was recorded for the effective_user (the ai_agent being represented)
    participant = decision.participants.find_by(user: @effective_user)
    assert_not_nil participant, "Represented user (ai_agent) should have a participant record"
  end

  # ====================
  # Stopping Representation
  # ====================

  test "parent can stop representing" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    delete "/u/#{@ai_agent.handle}/represent", headers: { "HTTP_REFERER" => "/" }

    assert_response :redirect
  end

  test "after stopping representation current_user returns the original person user" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    # Create a note while representing
    post "/studios/#{@collective.handle}/note", params: {
      note: { title: "Before stop", text: "Representing" },
    }
    note_while_representing = Note.last
    # While representing, content is attributed to the effective_user (the ai_agent)
    assert_equal @effective_user.id, note_while_representing.created_by_id

    # Stop representing
    delete "/u/#{@ai_agent.handle}/represent", headers: { "HTTP_REFERER" => "/studios/#{@collective.handle}" }

    # The stop_representing action should end the representation session
    rep_session = RepresentationSession.unscoped.find_by(trustee_grant: @grant, representative_user: @parent)
    rep_session.reload
    assert rep_session.ended?, "Representation session should be ended"

    follow_redirect!

    # Create another note after stopping
    post "/studios/#{@collective.handle}/note", params: {
      note: { title: "After stop", text: "No longer representing" },
    }
    note_after_stopping = Note.last
    assert_equal @parent.id, note_after_stopping.created_by_id
  end

  # ====================
  # Edge Cases
  # ====================

  test "if ai_agent user is archived during session representation ends gracefully" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    # Archive the ai_agent user while representing
    @ai_agent.tenant_user = @tenant.tenant_users.find_by(user: @ai_agent)
    @ai_agent.archive!

    # Access a page - should no longer be representing
    get "/studios/#{@collective.handle}"

    assert_response :success
    # The session should have cleared the representation since can_represent? returns false for archived users
  end

  test "representation is cleared when parent can no longer represent" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    # Revoke the grant (simulating an edge case where representation is no longer valid)
    @grant.revoke!

    # Access a page - representation should be cleared
    get "/studios/#{@collective.handle}"

    assert_response :success
    # Session should clear representation since the grant is revoked
  end

  test "cannot start representation for non-existent user" do
    sign_in_as(@parent, tenant: @tenant)

    post "/u/nonexistent-handle/represent"

    assert_response :not_found
  end

  test "representation persists across multiple requests" do
    sign_in_as(@parent, tenant: @tenant)
    start_representing

    # Make multiple requests
    get "/studios/#{@collective.handle}"
    assert_response :success

    get "/studios/#{@collective.handle}/cycles/today"
    assert_response :success

    # Create content on third request
    post "/studios/#{@collective.handle}/note", params: {
      note: { title: "Third request note", text: "Still representing" },
    }

    note = Note.last
    # Content is attributed to effective_user (the ai_agent being represented)
    assert_equal @effective_user.id, note.created_by_id
  end
end
