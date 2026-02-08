require "test_helper"

class TrusteeGrantsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!
    @user = @global_user

    # Create another user to delegate to/from
    @other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(@other_user)
    @superagent.add_user!(@other_user)

    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown")
  end

  # === Index Tests ===

  test "user can view their own trustee grants" do
    get "/u/#{@user.handle}/settings/trustee-grants", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Trustee Grants for"
  end

  test "granted trustee grants are listed in index" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-grants", headers: @headers
    assert_response :success
    # Check for display name or handle since the other_user's handle varies
    assert_includes response.body, @other_user.display_name || @other_user.name
  end

  test "received trustee grants are listed in index" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )
    permission.accept!

    get "/u/#{@user.handle}/settings/trustee-grants", headers: @headers
    assert_response :success
    # Check for display name or handle since the other_user's handle varies
    assert_includes response.body, @other_user.display_name || @other_user.name
  end

  # === New Page Tests ===

  test "user can view new trustee grant page" do
    get "/u/#{@user.handle}/settings/trustee-grants/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Create New Trustee Grant"
  end

  test "new page lists available users" do
    get "/u/#{@user.handle}/settings/trustee-grants/new", headers: @headers
    assert_response :success
    assert_includes response.body, @other_user.handle
  end

  test "new page lists available capabilities" do
    get "/u/#{@user.handle}/settings/trustee-grants/new", headers: @headers
    assert_response :success
    assert_includes response.body, "create_note"
    assert_includes response.body, "vote"
  end

  # === Create Tests ===

  test "user can create a trustee grant" do
    assert_difference "TrusteeGrant.unscoped.count" do
      post "/u/#{@user.handle}/settings/trustee-grants/new/actions/create_trustee_grant",
        params: {
          trusted_user_id: @other_user.id,
          permissions: ["create_note", "vote"],
          studio_scope_mode: "all",
        }.to_json,
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Trustee grant request sent"

    permission = TrusteeGrant.unscoped.order(created_at: :desc).first
    assert_equal @user, permission.granting_user
    assert_equal @other_user, permission.trusted_user
    assert permission.pending?
    assert permission.has_action_permission?("create_note")
    assert permission.has_action_permission?("vote")
  end

  test "create_trustee_grant requires trusted_user_id" do
    post "/u/#{@user.handle}/settings/trustee-grants/new/actions/create_trustee_grant",
      params: { permissions: ["create_note"] }.to_json,
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trusted user not found"
  end

  test "create_trustee_grant can set expiration" do
    expires = 1.week.from_now.iso8601
    post "/u/#{@user.handle}/settings/trustee-grants/new/actions/create_trustee_grant",
      params: {
        trusted_user_id: @other_user.id,
        permissions: ["create_note"],
        expires_at: expires,
      }.to_json,
      headers: @headers

    assert_response :success
    permission = TrusteeGrant.unscoped.order(created_at: :desc).first
    assert permission.expires_at.present?
  end

  test "create_trustee_grant can set studio scope" do
    post "/u/#{@user.handle}/settings/trustee-grants/new/actions/create_trustee_grant",
      params: {
        trusted_user_id: @other_user.id,
        permissions: ["create_note"],
        studio_scope_mode: "include",
        studio_ids: [@superagent.id],
      }.to_json,
      headers: @headers

    assert_response :success
    permission = TrusteeGrant.unscoped.order(created_at: :desc).first
    assert_equal "include", permission.studio_scope["mode"]
    assert_includes permission.studio_scope["studio_ids"], @superagent.id
  end

  # === Show Tests ===

  test "user can view a trustee grant they granted" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Trustee Grant:"
  end

  test "user can view a trustee grant they received" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
  end

  test "show page displays session history when sessions exist" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )
    grant.accept!

    # Create a user representation session linked to this grant (no superagent_id)
    session = RepresentationSession.create!(
      tenant: @tenant,
      representative_user: @user,
      trustee_user: grant.trustee_user,
      trustee_grant: grant,
      confirmed_understanding: true,
      began_at: 1.hour.ago,
      ended_at: 30.minutes.ago,
      activity_log: { "activity" => [] },
    )

    get "/u/#{@user.handle}/settings/trustee-grants/#{grant.truncated_id}", headers: @headers
    assert_response :success
    assert_includes response.body, "Session History"
    assert_includes response.body, session.truncated_id
  end

  test "show page displays empty state when no sessions exist" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-grants/#{grant.truncated_id}", headers: @headers
    assert_response :success
    assert_includes response.body, "Session History"
    assert_includes response.body, "No representation sessions"
  end

  # === Accept Tests ===

  test "trusted_user can accept a pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    assert permission.pending?

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/accept_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee grant accepted"

    permission.reload
    assert permission.active?
  end

  test "granting_user cannot accept a trustee grant they granted" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/accept_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "You can only accept trustee grants granted to you"

    permission.reload
    assert permission.pending?
  end

  test "cannot accept non-pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )
    permission.accept!

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/accept_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "not pending"
  end

  # === Decline Tests ===

  test "trusted_user can decline a pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/decline_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee grant declined"

    permission.reload
    assert permission.declined?
  end

  test "granting_user cannot decline a trustee grant they granted" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/decline_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "You can only decline trustee grants granted to you"

    permission.reload
    assert permission.pending?
  end

  # === Revoke Tests ===

  test "granting_user can revoke an active trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )
    permission.accept!

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/revoke_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee grant revoked"

    permission.reload
    assert permission.revoked?
  end

  test "granting_user can revoke a pending trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/revoke_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "Trustee grant revoked"

    permission.reload
    assert permission.revoked?
  end

  test "trusted_user cannot revoke a trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )
    permission.accept!

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/revoke_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "You can only revoke trustee grants you created"

    permission.reload
    assert permission.active?
  end

  test "cannot revoke already revoked trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )
    permission.accept!
    permission.revoke!

    post "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions/revoke_trustee_grant",
      headers: @headers

    assert_response :success
    assert_includes response.body, "already revoked"
  end

  # === Authorization Tests ===

  test "user cannot view trustee grants for other user" do
    get "/u/#{@other_user.handle}/settings/trustee-grants", headers: @headers
    assert_response :forbidden
    assert_includes response.body, "You don't have permission"
  end

  test "user cannot create trustee grant for other user" do
    third_user = create_user(email: "third_#{SecureRandom.hex(4)}@example.com", name: "Third User")
    @tenant.add_user!(third_user)

    assert_no_difference "TrusteeGrant.unscoped.count" do
      post "/u/#{@other_user.handle}/settings/trustee-grants/new/actions/create_trustee_grant",
        params: {
          trusted_user_id: third_user.id,
          permissions: ["create_note"],
        }.to_json,
        headers: @headers
    end

    assert_response :forbidden
  end

  # === Actions Index Tests ===

  test "actions index shows accept/decline for pending received trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @other_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_includes response.body, "accept_trustee_grant"
    assert_includes response.body, "decline_trustee_grant"
    assert_not_includes response.body, "revoke_trustee_grant"
  end

  test "actions index shows revoke for granted trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )

    get "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_includes response.body, "revoke_trustee_grant"
    assert_not_includes response.body, "accept_trustee_grant"
    assert_not_includes response.body, "decline_trustee_grant"
  end

  test "actions index shows no actions for revoked trustee grant" do
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: @other_user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_note" => true },
    )
    permission.revoke!

    get "/u/#{@user.handle}/settings/trustee-grants/#{permission.truncated_id}/actions", headers: @headers
    assert_response :success
    assert_not_includes response.body, "accept_trustee_grant"
    assert_not_includes response.body, "decline_trustee_grant"
    assert_not_includes response.body, "revoke_trustee_grant"
  end
end
