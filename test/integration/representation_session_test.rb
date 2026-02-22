require "test_helper"

class RepresentationSessionIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ====================
  # Starting Representation
  # ====================

  test "user with representative role can start representation" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }

    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_equal '/representing', path
  end

  test "user without representative role cannot start representation" do
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }

    assert_response :forbidden
  end

  test "user with any_member_can_represent setting can start representation" do
    @collective.settings['any_member_can_represent'] = true
    @collective.save!
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }

    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "must confirm understanding to start representation" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # First load the represent page
    get "/studios/#{@collective.handle}/represent"
    assert_response :success

    # Try without confirming understanding
    post "/studios/#{@collective.handle}/represent", params: { understand: 'false' },
         headers: { "HTTP_REFERER" => "/studios/#{@collective.handle}/represent" }

    assert_response :redirect
    follow_redirect!
    assert_match /You must check the box/, flash[:alert]
  end

  test "cannot start representation if already in active session" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start first session
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Try to start second session
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' },
         headers: { "HTTP_REFERER" => "/studios/#{@collective.handle}/represent" }

    assert_response :redirect
    follow_redirect!
    assert_match /Nested representation sessions are not allowed/, flash[:alert]
  end

  test "representation session is created when starting" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    assert_difference 'RepresentationSession.count', 1 do
      post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    end

    session = RepresentationSession.last
    assert_equal @user, session.representative_user
    # effective_user is the collective's trustee for studio representation
    assert_equal @collective.identity_user, session.effective_user
    assert_equal @collective, session.collective
    assert session.active?
  end

  # ====================
  # Actions While Representing
  # ====================

  test "creating note while representing attributes it to identity user" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Create a note while representing
    post "/studios/#{@collective.handle}/note", params: {
      note: {
        title: "Note from representation",
        text: "This should be attributed to the identity user",
      },
    }

    note = Note.last
    assert_equal @collective.identity_user.id, note.created_by_id
    assert_not_equal @user.id, note.created_by_id
  end

  test "activity is recorded in representation session" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Create a note while representing
    post "/studios/#{@collective.handle}/note", params: {
      note: {
        title: "Note for activity log",
        text: "This should be recorded in the session",
      },
    }

    session = RepresentationSession.last
    # The session should have recorded events
    assert session.action_count > 0
  end

  # ====================
  # Stopping Representation
  # ====================

  test "representative can stop their session" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    session = RepresentationSession.unscoped.where(collective_id: @collective.id).last
    assert_not_nil session, "RepresentationSession should have been created"
    assert_nil session.ended_at

    # Stop representation
    delete "/studios/#{@collective.handle}/represent"

    assert_response :redirect
    session.reload
    assert session.ended?
    assert session.ended_at.present?
  end

  test "after stopping representation current_user returns original user" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Create note while representing - should be trustee
    post "/studios/#{@collective.handle}/note", params: {
      note: { title: "During representation", text: "Trustee note" },
    }
    note_during = Note.last
    assert_equal @collective.identity_user.id, note_during.created_by_id

    # Stop representation
    delete "/studios/#{@collective.handle}/represent"
    follow_redirect!

    # Create note after stopping - should be user
    post "/studios/#{@collective.handle}/note", params: {
      note: { title: "After representation", text: "User note" },
    }
    note_after = Note.last
    assert_equal @user.id, note_after.created_by_id
  end

  # ====================
  # Viewing Representation Sessions
  # ====================

  test "representation session show page is accessible" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    session = create_representation_session(
      tenant: @tenant,
      collective: @collective,
      representative: @user,
    )
    session.end!
    sign_in_as(@user, tenant: @tenant)

    get "/studios/#{@collective.handle}/r/#{session.truncated_id}"

    assert_response :success
  end

  test "representation index shows sessions and representatives" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    session = create_representation_session(
      tenant: @tenant,
      collective: @collective,
      representative: @user,
    )
    session.end!
    sign_in_as(@user, tenant: @tenant)

    get "/studios/#{@collective.handle}/representation"

    assert_response :success
  end

  test "representation index only shows studio representation sessions, not user representation sessions" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')

    # Create a studio representation session (this SHOULD appear)
    studio_session = create_representation_session(
      tenant: @tenant,
      collective: @collective,
      representative: @user,
    )
    studio_session.end!

    # Create a user representation session via trustee grant (this should NOT appear)
    ai_agent = create_user(email: "ai_agent_#{SecureRandom.hex(4)}@example.com", name: "AiAgent User")
    @tenant.add_user!(ai_agent)
    @collective.add_user!(ai_agent)
    grant = create_trustee_grant(
      tenant: @tenant,
      granting_user: ai_agent,
      trustee_user: @user,
      accepted: true,
    )
    user_session = create_trustee_grant_representation_session(
      tenant: @tenant,
      trustee_grant: grant,
    )
    user_session.end!

    sign_in_as(@user, tenant: @tenant)

    get "/studios/#{@collective.handle}/representation"

    assert_response :success

    # The studio session ID should appear on the page
    assert_match studio_session.truncated_id, response.body,
      "Studio representation session should appear in the list"

    # The user session ID should NOT appear - this is the bug we're testing
    assert_no_match(/#{user_session.truncated_id}/, response.body,
      "User representation session should NOT appear on the studio representation page")
  end

  # ====================
  # Edge Cases
  # ====================

  test "if representative role is removed during session it ends gracefully" do
    collective_member = @collective.collective_members.find_by(user: @user)
    collective_member.add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # Remove representative role
    collective_member.remove_role!('representative')

    # Access a page - should end representation gracefully
    get "/studios/#{@collective.handle}"

    assert_response :success
    # Session should have been cleared since user can no longer represent
  end

  test "representation session expires after 24 hours" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    session = create_representation_session(
      tenant: @tenant,
      collective: @collective,
      representative: @user,
      began_at: 25.hours.ago,
    )

    assert session.expired?
    # Note: active? only checks ended_at, not expired?
    # But expired? does check if the session has exceeded 24 hours
  end

  test "non-member is redirected to join page" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)

    get "/studios/#{@collective.handle}/represent"

    # Non-members are redirected to join the studio
    assert_response :redirect
    assert_match /join/, response.location
  end

  test "unauthenticated user cannot start representation" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')

    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }

    assert_response :redirect
  end

  test "representation persists across multiple requests" do
    @collective.collective_members.find_by(user: @user).add_role!('representative')
    sign_in_as(@user, tenant: @tenant)

    # Start representation
    post "/studios/#{@collective.handle}/represent", params: { understand: 'true' }
    follow_redirect!

    # The /representing page should work
    get "/representing"
    assert_response :success

    # Access today's cycle
    get "/studios/#{@collective.handle}/cycles/today"
    assert_response :success

    # Create content - should still be attributed to trustee
    post "/studios/#{@collective.handle}/note", params: {
      note: { title: "Third request note", text: "Still representing" },
    }

    note = Note.last
    assert_equal @collective.identity_user.id, note.created_by_id
  end
end
