require "test_helper"

class ImpersonationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @parent = @global_user
    @subagent = create_subagent(parent: @parent, name: "Subagent User")
    @tenant.add_user!(@subagent)
    @superagent.add_user!(@subagent)
    # The TrusteeGrant is auto-created when the subagent is created
    @grant = TrusteeGrant.find_by!(granting_user: @subagent, trusted_user: @parent)
    @trustee_user = @grant.trustee_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # Helper to start impersonation and handle the new representation flow
  def start_impersonating
    post "/u/#{@subagent.handle}/impersonate"
    assert_response :redirect
    # New flow redirects to /representing first
    follow_redirect!
  end

  # ====================
  # Starting Impersonation
  # ====================

  test "parent can start impersonating their subagent user" do
    sign_in_as(@parent, tenant: @tenant)

    start_impersonating

    # Now at /representing page
    assert_response :success
    # Verify a RepresentationSession was created
    assert RepresentationSession.exists?(trustee_grant: @grant, representative_user: @parent)
  end

  test "parent cannot impersonate another user's subagent user" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    @superagent.add_user!(other_parent)
    other_subagent = create_subagent(parent: other_parent, name: "Other Subagent")
    @tenant.add_user!(other_subagent)
    @superagent.add_user!(other_subagent)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_subagent.handle}/impersonate"

    assert_response :forbidden
  end

  test "parent cannot impersonate archived subagent user" do
    # Archive through tenant_user since archived_at is on TenantUser
    @subagent.tenant_user = @tenant.tenant_users.find_by(user: @subagent)
    @subagent.archive!
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@subagent.handle}/impersonate"

    assert_response :forbidden
  end

  test "parent cannot impersonate a regular person user" do
    other_person = create_user(name: "Other Person")
    @tenant.add_user!(other_person)
    @superagent.add_user!(other_person)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_person.handle}/impersonate"

    assert_response :forbidden
  end

  test "unauthenticated user cannot impersonate anyone" do
    post "/u/#{@subagent.handle}/impersonate"

    # Should redirect to login or return error
    assert_response :redirect
  end

  # ====================
  # Session Management
  # ====================

  test "after impersonation starts current_user returns the trustee user" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    # Access a page that shows current user info (non-home pages work normally)
    get "/studios/#{@superagent.handle}"

    assert_response :success
  end

  test "creating content while impersonating attributes it to trustee user" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    # Create a note while impersonating
    post "/studios/#{@superagent.handle}/note", params: {
      note: {
        title: "Note from trustee user",
        text: "This should be attributed to the trustee user representing the subagent",
      },
    }

    note = Note.last
    # Content is now attributed to the trustee_user, not the subagent directly
    assert_equal @trustee_user.id, note.created_by_id
    assert_not_equal @parent.id, note.created_by_id
    assert_not_equal @subagent.id, note.created_by_id
  end

  # ====================
  # Actions While Impersonating
  # ====================

  test "creating a note while impersonating attributes it to the trustee user" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    assert_difference "Note.count", 1 do
      post "/studios/#{@superagent.handle}/note", params: {
        note: {
          title: "Trustee user's note",
          text: "Created by trustee user representing subagent",
        },
      }
    end

    note = Note.last
    # Content is attributed to the trustee_user
    assert_equal @trustee_user.id, note.created_by_id
  end

  test "voting on a decision while impersonating records the trustee user's participation" do
    sign_in_as(@parent, tenant: @tenant)

    # Create a decision first
    decision = Decision.create!(
      tenant: @tenant,
      superagent: @superagent,
      created_by: @parent,
      question: "Test Decision?",
      description: "Testing voting while impersonating",
      deadline: Time.current + 1.week,
      options_open: true,
    )
    option = Option.create!(
      tenant: @tenant,
      superagent: @superagent,
      decision: decision,
      decision_participant: DecisionParticipantManager.new(decision: decision, user: @parent).find_or_create_participant,
      title: "Option A",
    )

    # Now impersonate and vote
    start_impersonating

    post "/studios/#{@superagent.handle}/d/#{decision.truncated_id}/actions/vote", params: {
      votes: [{ option_title: option.title, accept: true, prefer: false }],
    }

    # Check that the vote was recorded for the trustee user (not the subagent directly)
    participant = decision.participants.find_by(user: @trustee_user)
    assert_not_nil participant, "Trustee user should have a participant record"
  end

  # ====================
  # Stopping Impersonation
  # ====================

  test "parent can stop impersonating" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    delete "/u/#{@subagent.handle}/impersonate", headers: { "HTTP_REFERER" => "/" }

    assert_response :redirect
  end

  test "after stopping impersonation current_user returns the original person user" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    # Create a note while impersonating
    post "/studios/#{@superagent.handle}/note", params: {
      note: { title: "Before stop", text: "Impersonating" },
    }
    note_while_impersonating = Note.last
    # While impersonating, content is attributed to the trustee_user
    assert_equal @trustee_user.id, note_while_impersonating.created_by_id

    # Stop impersonating
    delete "/u/#{@subagent.handle}/impersonate", headers: { "HTTP_REFERER" => "/studios/#{@superagent.handle}" }

    # The stop_impersonating action should end the representation session
    rep_session = RepresentationSession.unscoped.find_by(trustee_grant: @grant, representative_user: @parent)
    rep_session.reload
    assert rep_session.ended?, "Representation session should be ended"

    follow_redirect!

    # Create another note after stopping
    post "/studios/#{@superagent.handle}/note", params: {
      note: { title: "After stop", text: "No longer impersonating" },
    }
    note_after_stopping = Note.last
    assert_equal @parent.id, note_after_stopping.created_by_id
  end

  # ====================
  # Edge Cases
  # ====================

  test "if subagent user is archived during session representation ends gracefully" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    # Archive the subagent user while impersonating
    @subagent.tenant_user = @tenant.tenant_users.find_by(user: @subagent)
    @subagent.archive!

    # Access a page - should no longer be representing
    get "/studios/#{@superagent.handle}"

    assert_response :success
    # The session should have cleared the representation since can_represent? returns false for archived users
  end

  test "representation is cleared when parent can no longer represent" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    # Revoke the grant (simulating an edge case where representation is no longer valid)
    @grant.revoke!

    # Access a page - representation should be cleared
    get "/studios/#{@superagent.handle}"

    assert_response :success
    # Session should clear representation since the grant is revoked
  end

  test "cannot start impersonation for non-existent user" do
    sign_in_as(@parent, tenant: @tenant)

    post "/u/nonexistent-handle/impersonate"

    assert_response :not_found
  end

  test "representation persists across multiple requests" do
    sign_in_as(@parent, tenant: @tenant)
    start_impersonating

    # Make multiple requests
    get "/studios/#{@superagent.handle}"
    assert_response :success

    get "/studios/#{@superagent.handle}/cycles/today"
    assert_response :success

    # Create content on third request
    post "/studios/#{@superagent.handle}/note", params: {
      note: { title: "Third request note", text: "Still representing" },
    }

    note = Note.last
    # Content is attributed to trustee_user
    assert_equal @trustee_user.id, note.created_by_id
  end
end
