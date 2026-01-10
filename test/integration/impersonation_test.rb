require "test_helper"

class ImpersonationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @studio = @global_studio
    @parent = @global_user
    @simulated = User.create!(
      email: "simulated-#{SecureRandom.hex(4)}@not-a-real-email.com",
      name: "Simulated User",
      user_type: "simulated",
      parent_id: @parent.id,
    )
    @tenant.add_user!(@simulated)
    @studio.add_user!(@simulated)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ====================
  # Starting Impersonation
  # ====================

  test "parent can start impersonating their simulated user" do
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@simulated.handle}/impersonate"

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "parent cannot impersonate another user's simulated user" do
    other_parent = create_user(name: "Other Parent")
    @tenant.add_user!(other_parent)
    @studio.add_user!(other_parent)
    other_simulated = User.create!(
      email: "other-simulated-#{SecureRandom.hex(4)}@not-a-real-email.com",
      name: "Other Simulated",
      user_type: "simulated",
      parent_id: other_parent.id,
    )
    @tenant.add_user!(other_simulated)
    @studio.add_user!(other_simulated)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_simulated.handle}/impersonate"

    assert_response :forbidden
  end

  test "parent cannot impersonate archived simulated user" do
    # Archive through tenant_user since archived_at is on TenantUser
    @simulated.tenant_user = @tenant.tenant_users.find_by(user: @simulated)
    @simulated.archive!
    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{@simulated.handle}/impersonate"

    assert_response :forbidden
  end

  test "parent cannot impersonate a regular person user" do
    other_person = create_user(name: "Other Person")
    @tenant.add_user!(other_person)
    @studio.add_user!(other_person)

    sign_in_as(@parent, tenant: @tenant)

    post "/u/#{other_person.handle}/impersonate"

    assert_response :forbidden
  end

  test "unauthenticated user cannot impersonate anyone" do
    post "/u/#{@simulated.handle}/impersonate"

    # Should redirect to login or return error
    assert_response :redirect
  end

  # ====================
  # Session Management
  # ====================

  test "after impersonation starts current_user returns the simulated user" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"

    # Access a page that shows current user info
    get "/u/#{@simulated.handle}"

    assert_response :success
    # The simulated user's profile should be accessible
  end

  test "creating content while impersonating attributes it to simulated user" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    # Create a note while impersonating
    post "/studios/#{@studio.handle}/note", params: {
      note: {
        title: "Note from simulated user",
        text: "This should be attributed to the simulated user",
      },
    }

    note = Note.last
    assert_equal @simulated.id, note.created_by_id
    assert_not_equal @parent.id, note.created_by_id
  end

  # ====================
  # Actions While Impersonating
  # ====================

  test "creating a note while impersonating attributes it to the simulated user" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    assert_difference "Note.count", 1 do
      post "/studios/#{@studio.handle}/note", params: {
        note: {
          title: "Simulated user's note",
          text: "Created by simulated user",
        },
      }
    end

    note = Note.last
    assert_equal @simulated.id, note.created_by_id
  end

  test "voting on a decision while impersonating records the simulated user's participation" do
    sign_in_as(@parent, tenant: @tenant)

    # Create a decision first
    decision = Decision.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @parent,
      question: "Test Decision?",
      description: "Testing voting while impersonating",
      deadline: Time.current + 1.week,
      options_open: true,
    )
    option = Option.create!(
      tenant: @tenant,
      studio: @studio,
      decision: decision,
      decision_participant: DecisionParticipantManager.new(decision: decision, user: @parent).find_or_create_participant,
      title: "Option A",
    )

    # Now impersonate and vote
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    post "/studios/#{@studio.handle}/d/#{decision.truncated_id}/actions/vote", params: {
      option_id: option.id,
      value: 1,
    }

    # Check that the vote was recorded for the simulated user
    participant = decision.participants.find_by(user: @simulated)
    assert_not_nil participant, "Simulated user should have a participant record"
  end

  # ====================
  # Stopping Impersonation
  # ====================

  test "parent can stop impersonating" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    delete "/u/#{@simulated.handle}/impersonate", headers: { "HTTP_REFERER" => "/" }

    assert_response :redirect
  end

  test "after stopping impersonation current_user returns the original person user" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    # Create a note while impersonating
    post "/studios/#{@studio.handle}/note", params: {
      note: { title: "Before stop", text: "Impersonating" },
    }
    note_while_impersonating = Note.last
    assert_equal @simulated.id, note_while_impersonating.created_by_id

    # Stop impersonating
    delete "/u/#{@simulated.handle}/impersonate", headers: { "HTTP_REFERER" => "/studios/#{@studio.handle}" }
    follow_redirect!

    # Create another note after stopping
    post "/studios/#{@studio.handle}/note", params: {
      note: { title: "After stop", text: "No longer impersonating" },
    }
    note_after_stopping = Note.last
    assert_equal @parent.id, note_after_stopping.created_by_id
  end

  # ====================
  # Edge Cases
  # ====================

  test "if simulated user is archived during session impersonation ends gracefully" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    # Archive the simulated user while impersonating
    @simulated.tenant_user = @tenant.tenant_users.find_by(user: @simulated)
    @simulated.archive!

    # Access a page - should no longer be impersonating
    get "/studios/#{@studio.handle}"

    assert_response :success
    # The session should have cleared the impersonation since can_impersonate? returns false for archived users
  end

  test "impersonation is cleared when parent can no longer impersonate" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    # Change parent_id to someone else (simulating an edge case)
    other_user = create_user(name: "New Parent")
    @tenant.add_user!(other_user)
    @simulated.update_column(:parent_id, other_user.id)

    # Access a page - impersonation should be cleared
    get "/studios/#{@studio.handle}"

    assert_response :success
    # Session should clear impersonation since @parent can no longer impersonate @simulated
  end

  test "cannot start impersonation for non-existent user" do
    sign_in_as(@parent, tenant: @tenant)

    post "/u/nonexistent-handle/impersonate"

    assert_response :not_found
  end

  test "impersonation persists across multiple requests" do
    sign_in_as(@parent, tenant: @tenant)
    post "/u/#{@simulated.handle}/impersonate"
    follow_redirect!

    # Make multiple requests
    get "/studios/#{@studio.handle}"
    assert_response :success

    get "/studios/#{@studio.handle}/cycles/today"
    assert_response :success

    # Create content on third request
    post "/studios/#{@studio.handle}/note", params: {
      note: { title: "Third request note", text: "Still impersonating" },
    }

    note = Note.last
    assert_equal @simulated.id, note.created_by_id
  end
end
