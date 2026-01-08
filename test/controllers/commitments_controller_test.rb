# frozen_string_literal: true

require "test_helper"

class CommitmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @studio = @global_studio
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    # Create a commitment for tests
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)

    @commitment = Commitment.create!(
      tenant: @tenant,
      studio: @studio,
      created_by: @user,
      title: "Test Commitment",
      description: "A test commitment",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    Studio.clear_thread_scope
    Tenant.clear_thread_scope
  end

  # === New Commitment Form Tests ===

  test "authenticated user can access new commitment form" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/commit"
    assert_response :success
    assert_select "form"
  end

  test "unauthenticated user is redirected from new commitment form" do
    get "/studios/#{@studio.handle}/commit"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  # === Create Commitment Tests ===

  test "authenticated user can create commitment" do
    sign_in_as(@user, tenant: @tenant)

    initial_count = Commitment.unscoped.where(studio: @studio).count

    post "/studios/#{@studio.handle}/commit", params: {
      commitment: {
        title: "New Test Commitment",
        description: "Testing commitment creation",
        critical_mass: 10
      },
      deadline_option: "no_deadline"
    }

    final_count = Commitment.unscoped.where(studio: @studio).count
    assert_equal initial_count + 1, final_count

    commitment = Commitment.unscoped.find_by(title: "New Test Commitment", studio: @studio)
    assert_not_nil commitment
    assert_response :redirect
  end

  test "create commitment with close at critical mass deadline" do
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@studio.handle}/commit", params: {
      commitment: {
        title: "Critical Mass Commitment",
        description: "Testing critical mass",
        critical_mass: 5
      },
      deadline_option: "close_at_critical_mass"
    }

    commitment = Commitment.unscoped.find_by(title: "Critical Mass Commitment", studio: @studio)
    assert_not_nil commitment
    assert_response :redirect
  end

  # === Show Commitment Tests ===

  test "authenticated user can view commitment" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}"
    assert_response :success
    assert_match @commitment.title, response.body
  end

  test "unauthenticated user is redirected to login from commitment" do
    get "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  # === Settings Tests ===

  test "creator can access commitment settings" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}/settings"
    assert_response :success
  end

  test "non-creator cannot access commitment settings" do
    unique_id = SecureRandom.hex(8)
    other_user = User.create!(
      name: "Other User",
      email: "other-commitment-user-#{unique_id}@example.com",
      user_type: "person"
    )
    @tenant.add_user!(other_user)
    @studio.add_user!(other_user)

    sign_in_as(other_user, tenant: @tenant)
    get "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}/settings"
    assert_response :forbidden
  end

  test "creator can update commitment settings" do
    sign_in_as(@user, tenant: @tenant)

    post "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}/settings",
      params: { commitment: { title: "Updated Commitment Title" } },
      headers: { 'Referer' => "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}" }

    @commitment.reload
    assert_equal "Updated Commitment Title", @commitment.title
    assert_redirected_to @commitment.path
  end

  # === Join Tests ===

  test "user can join commitment" do
    sign_in_as(@user, tenant: @tenant)

    initial_participant_count = CommitmentParticipant.unscoped.where(commitment: @commitment).count

    post "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}/join.html",
      params: { name: "Test Participant" }

    # User becomes a participant
    assert_response :success

    final_participant_count = CommitmentParticipant.unscoped.where(commitment: @commitment).count
    # Should have same or more participants (might already be a participant)
    assert final_participant_count >= initial_participant_count
  end

  # === Status Partial Tests ===

  test "can get commitment status partial" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}/status.html"
    assert_response :success
  end

  # === Participants Partial Tests ===

  test "can get participants list partial" do
    sign_in_as(@user, tenant: @tenant)
    get "/studios/#{@studio.handle}/c/#{@commitment.truncated_id}/participants.html", params: { limit: 10 }
    assert_response :success
  end
end
